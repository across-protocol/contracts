// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./SpokePool.sol";

interface ZkBridgeLike {
    function withdraw(
        address _to,
        address _l2Token,
        uint256 _amount
    ) external;
}

interface IL2ETH {
    function withdraw(address _receiver) external payable;
}

/**
 * @notice ZkSync specific SpokePool, intended to be compiled with `@matterlabs/hardhat-zksync-solc`.
 */
contract ZkSync_SpokePool is SpokePool {
    // ETH is an ERC20 on ZkSync.
    address public l2Eth = 0x000000000000000000000000000000000000800A;

    // On Ethereum, avoiding constructor parameters and putting them into constants reduces some of the gas cost
    // upon contract deployment. On zkSync the opposite is true: deploying the same bytecode for contracts,
    // while changing only constructor parameters can lead to substantial fee savings. So, the following params
    // are all set by passing in constructor params where possible.

    // However, this contract is expected to be deployed only once to ZkSync. Therefore, we should consider the cost
    // of reading mutable vs immutable storage. On Ethereum, mutable storage is more expensive than immutable bytecode.
    // But, we also want to be able to upgrade certain state variables.

    // Bridge used to withdraw ERC20's to L1
    ZkBridgeLike public zkErc20Bridge;

    event SetZkBridges(address indexed erc20Bridge);
    event ZkSyncTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged);

    /**
     * @notice Construct the ZkSync SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _zkErc20Bridge Address of L2 ERC20 gateway. Can be reset by admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wethAddress Weth address for this network to set.
     * @param _timerAddress Timer address to set.
     */
    function initialize(
        uint32 _initialDepositId,
        ZkBridgeLike _zkErc20Bridge,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address _timerAddress
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, _wethAddress, _timerAddress);
        _setZkBridges(_zkErc20Bridge);
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
    function setZkBridges(ZkBridgeLike _zkErc20Bridge) public onlyAdmin nonReentrant {
        _setZkBridges(_zkErc20Bridge);
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
        // TODO: Figure out whether SpokePool will receive L1-->L2 deposits in ETH or WETH and whether ETH or WETH
        // can be withdrawn. If ETH is received and must be withdrawn, then we need to wrap it upon receiving it and
        // unwrap it when withdrawing.
        emit ZkSyncTokensBridged(relayerRefundLeaf.l2TokenAddress, hubPool, relayerRefundLeaf.amountToReturn);
        if (relayerRefundLeaf.l2TokenAddress == address(wrappedNativeToken)) {
            WETH9Interface(relayerRefundLeaf.l2TokenAddress).withdraw(relayerRefundLeaf.amountToReturn); // Unwrap into ETH.
            // To withdraw tokens, we actually call 'withdraw' on the L2 eth token itself.
            IL2ETH(l2Eth).withdraw{ value: relayerRefundLeaf.amountToReturn }(hubPool);
        } else {
            zkErc20Bridge.withdraw(hubPool, relayerRefundLeaf.l2TokenAddress, relayerRefundLeaf.amountToReturn);
        }
    }

    function _setZkBridges(ZkBridgeLike _zkErc20Bridge) internal {
        zkErc20Bridge = _zkErc20Bridge;
        emit SetZkBridges(address(_zkErc20Bridge));
    }

    // L1 addresses are transformed during l1->l2 calls.
    // See https://github.com/matter-labs/era-contracts/blob/main/docs/Overview.md#mailboxfacet for more information.
    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        unchecked {
            l2Address = address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
        }
    }

    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}
}
