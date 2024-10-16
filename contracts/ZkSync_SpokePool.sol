// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import { CrossDomainAddressUtils } from "./libraries/CrossDomainAddressUtils.sol";

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
contract ZkSync_SpokePool is SpokePool {
    using AddressToBytes32 for address;
    // On Ethereum, avoiding constructor parameters and putting them into constants reduces some of the gas cost
    // upon contract deployment. On zkSync the opposite is true: deploying the same bytecode for contracts,
    // while changing only constructor parameters can lead to substantial fee savings. So, the following params
    // are all set by passing in constructor params where possible.

    // ETH on ZkSync implements a subset of the ERC-20 interface, with additional built-in support to bridge to L1.
    address public l2Eth;

    // Bridge used to withdraw ERC20's to L1
    ZkBridgeLike public zkErc20Bridge;

    event SetZkBridge(address indexed erc20Bridge, address indexed oldErc20Bridge);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the ZkSync SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _zkErc20Bridge Address of L2 ERC20 gateway. Can be reset by admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     */
    function initialize(
        uint32 _initialDepositId,
        ZkBridgeLike _zkErc20Bridge,
        address _crossDomainAdmin,
        address _hubPool
    ) public initializer {
        l2Eth = 0x000000000000000000000000000000000000800A;
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool);
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
    function _preExecuteLeafHook(bytes32 l2TokenAddress) internal override {
        if (l2TokenAddress == address(wrappedNativeToken).toBytes32()) _depositEthToWeth();
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
            IL2ETH(l2Eth).withdraw{ value: amountToReturn }(hubPool);
        } else {
            zkErc20Bridge.withdraw(hubPool, l2TokenAddress, amountToReturn);
        }
    }

    function _setZkBridge(ZkBridgeLike _zkErc20Bridge) internal {
        address oldErc20Bridge = address(zkErc20Bridge);
        zkErc20Bridge = _zkErc20Bridge;
        emit SetZkBridge(address(_zkErc20Bridge), oldErc20Bridge);
    }

    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}
}
