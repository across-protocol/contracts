// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "@eth-optimism/contracts/libraries/bridge/CrossDomainEnabled.sol";
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

/**
 * @notice OVM specific SpokePool. Uses OVM cross-domain-enabled logic to implement admin only access to functions. * Optimism and Boba each implement this spoke pool and set their chain specific contract addresses for l2Eth and l2Weth.
 */
contract Ovm_SpokePool is CrossDomainEnabled, SpokePool {
    // Stores alternative token bridges to use for L2 tokens that don't go over the standard bridge. This is needed
    // to support non-standard ERC20 tokens on Optimism, such as DIA and SNX which both use custom bridges.
    mapping(address => address) public tokenBridges;

    event SetL1Gas(uint32 indexed newL1Gas);
    event SetL2TokenBridge(address indexed l2Token, address indexed tokenBridge);

    /**
     * @notice Construct the OVM SpokePool.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param timerAddress Timer address to set.
     */
    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address _wrappedNativeToken,
        address timerAddress
    )
        CrossDomainEnabled(Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER)
        SpokePool(_crossDomainAdmin, _hubPool, _wrappedNativeToken, timerAddress)
    {}

    /*******************************************
     *    OPTIMISM-SPECIFIC ADMIN FUNCTIONS    *
     *******************************************/

    /**
     * @notice Set bridge contract for L2 token used to withdraw back to L1.
     * @dev If this mapping isn't set for an L2 token, then the standard bridge will be used to bridge this token.
     * @param tokenBridge Address of token bridge
     */
    function setTokenBridge(address l2Token, address tokenBridge) public onlyAdmin nonReentrant {
        tokenBridges[l2Token] = tokenBridge;
        emit SetL2TokenBridge(l2Token, tokenBridge);
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
        uint64 realizedLpFeePct,
        uint64 relayerFeePct,
        uint32 depositId,
        uint32 rootBundleId,
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
    // this SpokePool will receive ETH from the canonical token bridge instead of WETH. Its not sufficient to execute
    // this logic inside a fallback method that executes when this contract receives ETH because ETH is an ERC20
    // on the OVM.
    function _depositEthToWeth() internal {
        if (address(this).balance > 0) wrappedNativeToken.deposit{ value: address(this).balance }();
    }

    // Apply OVM-specific transformation to cross domain admin address on L1.
    function _requireAdminSender() internal override onlyFromCrossDomainAccount(crossDomainAdmin) {}
}
