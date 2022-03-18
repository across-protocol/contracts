// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "./interfaces/WETH9.sol";

import "@eth-optimism/contracts/libraries/bridge/CrossDomainEnabled.sol";
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";
import "@eth-optimism/contracts/L2/messaging/IL2ERC20Bridge.sol";

/**
 * @notice OVM specific SpokePool. Uses OVM cross-domain-enabled logic to implement admin only access to functions.
 */
contract Optimism_SpokePool is CrossDomainEnabled, SpokePool {
    // "l1Gas" parameter used in call to bridge tokens from this contract back to L1 via IL2ERC20Bridge. Currently
    // unused by bridge but included for future compatibility.
    uint32 public l1Gas = 5_000_000;

    // ETH is an ERC20 on OVM.
    address public immutable l2Eth = address(Lib_PredeployAddresses.OVM_ETH);

    // Stores alternative token bridges to use for L2 tokens that don't go over the standard bridge. This is needed
    // to support non-standard ERC20 tokens on Optimism, such as DIA and SNX which both use custom bridges.
    mapping(address => address) public tokenBridges;

    event OptimismTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged, uint256 l1Gas);
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
        address timerAddress
    )
        CrossDomainEnabled(Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER)
        SpokePool(_crossDomainAdmin, _hubPool, 0x4200000000000000000000000000000000000006, timerAddress)
    {}

    /*******************************************
     *    OPTIMISM-SPECIFIC ADMIN FUNCTIONS    *
     *******************************************/

    /**
     * @notice Change L1 gas limit. Callable only by admin.
     * @param newl1Gas New L1 gas limit to set.
     */
    function setL1GasLimit(uint32 newl1Gas) public onlyAdmin nonReentrant {
        l1Gas = newl1Gas;
        emit SetL1Gas(newl1Gas);
    }

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
    function executeSlowRelayRoot(
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
        if (destinationToken == address(weth)) _depositEthToWeth();

        _executeSlowRelayRoot(
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
    function executeRelayerRefundRoot(
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) public override(SpokePool) nonReentrant {
        if (relayerRefundLeaf.l2TokenAddress == address(weth)) _depositEthToWeth();

        _executeRelayerRefundRoot(rootBundleId, relayerRefundLeaf, proof);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    // Wrap any ETH owned by this contract so we can send expected L2 token to recipient. This is necessary because
    // this SpokePool will receive ETH from the canonical token bridge instead of WETH. Its not sufficient to execute
    // this logic inside a fallback method that executes when this contract receives ETH because ETH is an ERC20
    // on the OVM.
    function _depositEthToWeth() internal {
        if (address(this).balance > 0) weth.deposit{ value: address(this).balance }();
    }

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        // If the token being bridged is WETH then we need to first unwrap it to ETH and then send ETH over the
        // canonical bridge. On Optimism, this is address 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000.
        if (relayerRefundLeaf.l2TokenAddress == address(weth)) {
            WETH9(relayerRefundLeaf.l2TokenAddress).withdraw(relayerRefundLeaf.amountToReturn); // Unwrap into ETH.
            relayerRefundLeaf.l2TokenAddress = l2Eth; // Set the l2TokenAddress to ETH.
        }
        IL2ERC20Bridge(
            tokenBridges[relayerRefundLeaf.l2TokenAddress] == address(0)
                ? Lib_PredeployAddresses.L2_STANDARD_BRIDGE
                : tokenBridges[relayerRefundLeaf.l2TokenAddress]
        ).withdrawTo(
                relayerRefundLeaf.l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
                hubPool, // _to. Withdraw, over the bridge, to the l1 pool contract.
                relayerRefundLeaf.amountToReturn, // _amount.
                l1Gas, // _l1Gas. Unused, but included for potential forward compatibility considerations
                "" // _data. We don't need to send any data for the bridging action.
            );

        emit OptimismTokensBridged(relayerRefundLeaf.l2TokenAddress, hubPool, relayerRefundLeaf.amountToReturn, l1Gas);
    }

    // Apply OVM-specific transformation to cross domain admin address on L1.
    function _requireAdminSender() internal override onlyFromCrossDomainAccount(crossDomainAdmin) {}
}
