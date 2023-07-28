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

interface IL2ETH {
    function withdraw(address _l1Receiver) external payable;
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

    // ETH on ZkSync implements a subset of the ERC-20 interface, with additional built-in support to bridge to L1.
    address public l2Eth;

    // Bridge used to withdraw ERC20's to L1
    ZkBridgeLike public zkErc20Bridge;

    event SetZkBridge(address indexed erc20Bridge);
    event ZkSyncTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged);

    /**
     * @notice Construct the ZkSync SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _zkErc20Bridge Address of L2 ERC20 gateway. Can be reset by admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wethAddress Weth address for this network to set.
     */
    function initialize(
        uint32 _initialDepositId,
        ZkBridgeLike _zkErc20Bridge,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress
    ) public initializer {
        l2Eth = 0x000000000000000000000000000000000000800A;
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, _wethAddress);
        _setZkBridge(_zkErc20Bridge);
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
     */
    function setZkBridge(ZkBridgeLike _zkErc20Bridge) public onlyAdmin nonReentrant {
        _setZkBridge(_zkErc20Bridge);
    }

    /**************************************
     *         DATA WORKER FUNCTIONS      *
     **************************************/

    /**
     * @notice Wraps any ETH into WETH before executing base function. This is necessary because SpokePool receives
     * ETH over the canonical token bridge instead of WETH.
     * @inheritdoc SpokePool
     */
    function executeSlowRelayLeaf(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 totalRelayAmount,
        uint256 originChainId,
        int64 realizedLpFeePct,
        int64 relayerFeePct,
        uint32 depositId,
        uint32 rootBundleId,
        bytes memory message,
        int256 payoutAdjustment,
        bytes32[] memory proof
    ) public override(SpokePool) nonReentrant {
        if (destinationToken == address(wrappedNativeToken)) _depositEthToWeth();

        _executeSlowRelayLeaf(
            depositor,
            recipient,
            destinationToken,
            totalRelayAmount,
            originChainId,
            chainId(),
            realizedLpFeePct,
            relayerFeePct,
            depositId,
            rootBundleId,
            message,
            payoutAdjustment,
            proof
        );
    }

    /**
     * @notice Wraps any ETH into WETH before executing base function. This is necessary because SpokePool receives
     * ETH over the canonical token bridge instead of WETH.
     * @inheritdoc SpokePool
     */
    function executeRelayerRefundLeaf(
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) public override(SpokePool) nonReentrant {
        if (relayerRefundLeaf.l2TokenAddress == address(wrappedNativeToken)) _depositEthToWeth();

        _executeRelayerRefundLeaf(rootBundleId, relayerRefundLeaf, proof);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    // Wrap any ETH owned by this contract so we can send expected L2 token to recipient. This is necessary because
    // this SpokePool will receive ETH from the canonical token bridge instead of WETH. This may not be neccessary
    // if ETH on ZkSync is treated as ETH and the fallback() function is triggered when this contract receives
    // ETH. We will have to test this but this function for now allows the contract to safely convert all of its
    // held ETH into WETH at the cost of higher gas costs.
    function _depositEthToWeth() internal {
        //slither-disable-next-line arbitrary-send-eth
        if (address(this).balance > 0) wrappedNativeToken.deposit{ value: address(this).balance }();
    }

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        // SpokePool is expected to receive ETH from the L1 HubPool and currently, withdrawing ETH directly
        // over the ERC20 Bridge is blocked at the contract level. Therefore, we need to unwrap it before withdrawing.
        if (relayerRefundLeaf.l2TokenAddress == address(wrappedNativeToken)) {
            WETH9Interface(relayerRefundLeaf.l2TokenAddress).withdraw(relayerRefundLeaf.amountToReturn); // Unwrap into ETH.
            // To withdraw tokens, we actually call 'withdraw' on the L2 eth token itself.
            IL2ETH(l2Eth).withdraw{ value: relayerRefundLeaf.amountToReturn }(hubPool);
        } else {
            zkErc20Bridge.withdraw(hubPool, relayerRefundLeaf.l2TokenAddress, relayerRefundLeaf.amountToReturn);
        }
        emit ZkSyncTokensBridged(relayerRefundLeaf.l2TokenAddress, hubPool, relayerRefundLeaf.amountToReturn);
    }

    function _setZkBridge(ZkBridgeLike _zkErc20Bridge) internal {
        zkErc20Bridge = _zkErc20Bridge;
        emit SetZkBridge(address(_zkErc20Bridge));
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
