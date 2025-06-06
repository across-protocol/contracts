// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CircleCCTPAdapter, CircleDomainIds, ITokenMessenger } from "./libraries/CircleCCTPAdapter.sol";
import { CrossDomainAddressUtils } from "./libraries/CrossDomainAddressUtils.sol";
import "./SpokePool.sol";

// https://github.com/matter-labs/era-contracts/blob/6391c0d7bf6184d7f6718060e3991ba6f0efe4a7/zksync/contracts/bridge/L2ERC20Bridge.sol#L104
interface ZkBridgeLike {
    function withdraw(
        address _l1Receiver,
        address _l2Token,
        uint256 _amount
    ) external;
}

interface IL2ETH {
    function withdraw(address _l1Receiver) external payable;
}

/**
 * @notice ZkSync specific SpokePool, intended to be compiled with `@matterlabs/hardhat-zksync-solc`.
 * @dev Resources for compiling and deploying contracts with hardhat: https://era.zksync.io/docs/tools/hardhat/hardhat-zksync-solc.html
 * @custom:security-contact bugs@across.to
 */
contract ZkSync_SpokePool is SpokePool, CircleCCTPAdapter {
    using SafeERC20 for IERC20;

    // On Ethereum, avoiding constructor parameters and putting them into constants reduces some of the gas cost
    // upon contract deployment. On zkSync the opposite is true: deploying the same bytecode for contracts,
    // while changing only constructor parameters can lead to substantial fee savings. So, the following params
    // are all set by passing in constructor params where possible.

    // ETH on ZkSync implements a subset of the ERC-20 interface, with additional built-in support to bridge to L1.
    address public l2Eth;

    // Bridge used to withdraw ERC20's to L1
    ZkBridgeLike public zkErc20Bridge;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    ZkBridgeLike public immutable zkUSDCBridge;

    event SetZkBridge(address indexed erc20Bridge, address indexed oldErc20Bridge);

    error InvalidBridgeConfig();

    /**
     * @notice Constructor.
     * @notice Circle bridged & native USDC are optionally supported via configuration, but are mutually exclusive.
     * @param _wrappedNativeTokenAddress wrappedNativeToken address for this network to set.
     * @param _circleUSDC Circle USDC address on the SpokePool. Set to 0x0 to use the standard ERC20 bridge instead.
     * If not set to zero, then either the zkUSDCBridge or cctpTokenMessenger must be set and will be used to
     * bridge this token.
     * @param _zkUSDCBridge Elastic chain custom bridge address for USDC (if deployed, or address(0) to disable).
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP. If the zero address is passed, CCTP bridging will be disabled.
     * @param _depositQuoteTimeBuffer depositQuoteTimeBuffer to set. Quote timestamps can't be set more than this amount
     * into the past from the block time of the deposit.
     * @param _fillDeadlineBuffer fillDeadlineBuffer to set. Fill deadlines can't be set more than this amount
     * into the future from the block time of the deposit.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        IERC20 _circleUSDC,
        ZkBridgeLike _zkUSDCBridge,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    )
        SpokePool(
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            // ZkSync_SpokePool does not use OFT messaging; setting destination eid and fee cap to 0
            0,
            0
        )
        CircleCCTPAdapter(_circleUSDC, _cctpTokenMessenger, CircleDomainIds.Ethereum)
    {
        address zero = address(0);
        if (address(_circleUSDC) != zero) {
            bool zkUSDCBridgeDisabled = address(_zkUSDCBridge) == zero;
            bool cctpUSDCBridgeDisabled = address(_cctpTokenMessenger) == zero;
            // Bridged and Native USDC are mutually exclusive.
            if (zkUSDCBridgeDisabled == cctpUSDCBridgeDisabled) {
                revert InvalidBridgeConfig();
            }
        }

        zkUSDCBridge = _zkUSDCBridge;
    }

    /**
     * @notice Initialize the ZkSync SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _zkErc20Bridge Address of L2 ERC20 gateway. Can be reset by admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _withdrawalRecipient Address which receives token withdrawals. Can be changed by admin. For Spoke Pools on L2, this will
     * likely be the hub pool.
     */
    function initialize(
        uint32 _initialDepositId,
        ZkBridgeLike _zkErc20Bridge,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        l2Eth = 0x000000000000000000000000000000000000800A;
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient);
        _setZkBridge(_zkErc20Bridge);
    }

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == CrossDomainAddressUtils.applyL1ToL2Alias(crossDomainAdmin), "ONLY_COUNTERPART_GATEWAY");
        _;
    }

    /********************************************************
     *      ZKSYNC-SPECIFIC CROSS-CHAIN ADMIN FUNCTIONS     *
     ********************************************************/

    /**
     * @notice Change L2 token bridge addresses. Callable only by admin.
     * @param _zkErc20Bridge New address of L2 ERC20 gateway.
     */
    function setZkBridge(ZkBridgeLike _zkErc20Bridge) public onlyAdmin nonReentrant {
        _setZkBridge(_zkErc20Bridge);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    /**
     * @notice Wraps any ETH into WETH before executing base function. This is necessary because SpokePool receives
     * ETH over the canonical token bridge instead of WETH.
     */
    function _preExecuteLeafHook(address l2TokenAddress) internal override {
        if (l2TokenAddress == address(wrappedNativeToken)) _depositEthToWeth();
    }

    // Wrap any ETH owned by this contract so we can send expected L2 token to recipient. This is necessary because
    // this SpokePool will receive ETH from the canonical token bridge instead of WETH. This may not be neccessary
    // if ETH on ZkSync is treated as ETH and the fallback() function is triggered when this contract receives
    // ETH. We will have to test this but this function for now allows the contract to safely convert all of its
    // held ETH into WETH at the cost of higher gas costs.
    function _depositEthToWeth() internal {
        //slither-disable-next-line arbitrary-send-eth
        if (address(this).balance > 0) wrappedNativeToken.deposit{ value: address(this).balance }();
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        // SpokePool is expected to receive ETH from the L1 HubPool and currently, withdrawing ETH directly
        // over the ERC20 Bridge is blocked at the contract level. Therefore, we need to unwrap it before withdrawing.
        if (l2TokenAddress == address(wrappedNativeToken)) {
            WETH9Interface(l2TokenAddress).withdraw(amountToReturn); // Unwrap into ETH.
            // To withdraw tokens, we actually call 'withdraw' on the L2 eth token itself.
            IL2ETH(l2Eth).withdraw{ value: amountToReturn }(withdrawalRecipient);
        } else if (l2TokenAddress == address(usdcToken)) {
            if (_isCCTPEnabled()) {
                // Circle native USDC via CCTP.
                _transferUsdc(withdrawalRecipient, amountToReturn);
            } else {
                // Matter Labs custom USDC bridge for Circle Bridged (upgradable) USDC.
                IERC20(l2TokenAddress).forceApprove(address(zkUSDCBridge), amountToReturn);
                zkUSDCBridge.withdraw(withdrawalRecipient, l2TokenAddress, amountToReturn);
            }
        } else {
            zkErc20Bridge.withdraw(withdrawalRecipient, l2TokenAddress, amountToReturn);
        }
    }

    function _setZkBridge(ZkBridgeLike _zkErc20Bridge) internal {
        address oldErc20Bridge = address(zkErc20Bridge);
        zkErc20Bridge = _zkErc20Bridge;
        emit SetZkBridge(address(_zkErc20Bridge), oldErc20Bridge);
    }

    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}

    // Reserve storage slots for future versions of this base contract to add state variables without
    // affecting the storage layout of child contracts. Decrement the size of __gap whenever state variables
    // are added, so that the total number of slots taken by this contract remains constant. Per-contract
    // storage layout information  can be found in storage-layouts/
    // This is at bottom of contract to make sure it's always at the end of storage.
    uint256[999] private __gap;
}
