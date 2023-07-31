// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";

// https://github.com/matter-labs/era-contracts/blob/6391c0d7bf6184d7f6718060e3991ba6f0efe4a7/zksync/contracts/bridge/L2ERC20Bridge.sol#L104
interface ZkBridgeLike {
    function withdraw(
        address _l1Receiver,
        address _l2Token,
        uint256 _amount
    ) external;
}

/**
 * @notice ZkSync specific SpokePool, intended to be compiled with `@matterlabs/hardhat-zksync-solc`.
 * @dev Resources for compiling and deploying contracts with hardhat: https://era.zksync.io/docs/tools/hardhat/hardhat-zksync-solc.html
 */
contract ZkSync_SpokePool is SpokePool {
    // On Ethereum, avoiding constructor parameters and putting them into constants reduces some of the gas cost
    // upon contract deployment. On zkSync the opposite is true: deploying the same bytecode for contracts,
    // while changing only constructor parameters can lead to substantial fee savings. So, the following params
    // are all set by passing in constructor params where possible.

    // Bridges used to withdraw ERC20's to L1
    ZkBridgeLike public zkErc20Bridge;
    ZkBridgeLike public zkWETHBridge;

    event SetZkBridge(
        address indexed erc20Bridge,
        address oldErc20Bridge,
        address indexed wethBridge,
        address oldWethBridge
    );
    event ZkSyncTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged);

    /**
     * @notice Construct the ZkSync SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _zkErc20Bridge Address of L2 ERC20 gateway. Can be reset by admin.
     * @param _zkWETHBridge Address of L2 WETH gateway. Can be reset by admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wethAddress Weth address for this network to set.
     */
    function initialize(
        uint32 _initialDepositId,
        ZkBridgeLike _zkErc20Bridge,
        ZkBridgeLike _zkWETHBridge,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, _wethAddress);
        _setZkBridge(_zkErc20Bridge, _zkWETHBridge);
    }

    /**
     * Initializes second implementation of this contract that uses a special WETH bridge for more gas efficient
     * WETH bridging, as opposed to having to unwrap WETH --> ETH before bridging the ETH.
     * @param _zkErc20Bridge Address of L2 ERC20 gateway. Can be reset by admin.
     * @param _zkWETHBridge Address of L2 WETH gateway. Can be reset by admin.
     */
    function initialize_v2(ZkBridgeLike _zkErc20Bridge, ZkBridgeLike _zkWETHBridge) public reinitializer(2) {
        _setZkBridge(_zkErc20Bridge, _zkWETHBridge);
    }

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == _applyL1ToL2Alias(crossDomainAdmin), "ONLY_COUNTERPART_GATEWAY");
        _;
    }

    /********************************************************
     *      ZKSYNC-SPECIFIC CROSS-CHAIN ADMIN FUNCTIONS     *
     ********************************************************/

    /**
     * @notice Change L2 token bridge addresses. Callable only by admin.
     * @param _zkErc20Bridge New address of L2 ERC20 gateway.
     * @param _zkWETHBridge New address of L2 WETH gateway.
     */
    function setZkBridge(ZkBridgeLike _zkErc20Bridge, ZkBridgeLike _zkWETHBridge) public onlyAdmin nonReentrant {
        _setZkBridge(_zkErc20Bridge, _zkWETHBridge);
    }

    /**************************************
     *         PUBLIC FUNCTIONS      *
     **************************************/

    /**
     * @notice Wrap any ETH accidentally sent to this contract into WETH
     */
    function depositEthToWeth() external nonReentrant {
        //slither-disable-next-line arbitrary-send-eth
        if (address(this).balance > 0) wrappedNativeToken.deposit{ value: address(this).balance }();
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        if (relayerRefundLeaf.l2TokenAddress == address(wrappedNativeToken)) {
            zkWETHBridge.withdraw(hubPool, relayerRefundLeaf.l2TokenAddress, relayerRefundLeaf.amountToReturn);
        } else {
            zkErc20Bridge.withdraw(hubPool, relayerRefundLeaf.l2TokenAddress, relayerRefundLeaf.amountToReturn);
        }
        emit ZkSyncTokensBridged(relayerRefundLeaf.l2TokenAddress, hubPool, relayerRefundLeaf.amountToReturn);
    }

    function _setZkBridge(ZkBridgeLike _zkErc20Bridge, ZkBridgeLike _zkWETHBridge) internal {
        address oldZkErc20Bridge = address(zkErc20Bridge);
        address oldZkWETHBridge = address(zkWETHBridge);
        zkErc20Bridge = _zkErc20Bridge;
        zkWETHBridge = _zkWETHBridge;
        emit SetZkBridge(address(_zkErc20Bridge), oldZkErc20Bridge, address(_zkWETHBridge), oldZkWETHBridge);
    }

    // L1 addresses are transformed during l1->l2 calls.
    // See https://github.com/matter-labs/era-contracts/blob/main/docs/Overview.md#mailboxfacet for more information.
    // Another source: https://github.com/matter-labs/era-contracts/blob/41c25aa16d182f757c3fed1463c78a81896f65e6/ethereum/contracts/vendor/AddressAliasHelper.sol#L28
    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        unchecked {
            l2Address = address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
        }
    }

    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}
}
