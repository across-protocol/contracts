// SPDX-License-Identifier: BUSL-1.1

// Arbitrum only supports v0.8.19
// See https://docs.arbitrum.io/for-devs/concepts/differences-between-arbitrum-ethereum/solidity-support#differences-from-solidity-on-ethereum
pragma solidity ^0.8.19;

import "./SpokePool.sol";
import "./libraries/CircleCCTPAdapter.sol";

interface StandardBridgeLike {
    function outboundTransfer(
        address _l1Token,
        address _to,
        uint256 _amount,
        bytes calldata _data
    ) external payable returns (bytes memory);
}

/**
 * @notice AVM specific SpokePool. Uses AVM cross-domain-enabled logic to implement admin only access to functions.
 * @custom:security-contact bugs@across.to
 */
contract AlephZero_SpokePool is SpokePool, CircleCCTPAdapter {
    // Address of the Arbitrum L2 token gateway to send funds to L1.
    address public l2GatewayRouter;

    // Admin controlled mapping of arbitrum tokens to L1 counterpart. L1 counterpart addresses
    // are necessary params used when bridging tokens to L1.
    mapping(address => address) public whitelistedTokens;

    event SetL2GatewayRouter(address indexed newL2GatewayRouter);
    event WhitelistedTokens(address indexed l2Token, address indexed l1Token);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger
    )
        SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer)
        CircleCCTPAdapter(_l2Usdc, _cctpTokenMessenger, CircleDomainIds.Ethereum)
    {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the AVM SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _l2GatewayRouter Address of L2 token gateway. Can be reset by admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     */
    function initialize(
        uint32 _initialDepositId,
        address _l2GatewayRouter,
        address _crossDomainAdmin,
        address _hubPool
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool);
        _setL2GatewayRouter(_l2GatewayRouter);
    }

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == _applyL1ToL2Alias(crossDomainAdmin), "ONLY_COUNTERPART_GATEWAY");
        _;
    }

    /********************************************************
     *    ARBITRUM-SPECIFIC CROSS-CHAIN ADMIN FUNCTIONS     *
     ********************************************************/

    /**
     * @notice Change L2 gateway router. Callable only by admin.
     * @param newL2GatewayRouter New L2 gateway router.
     */
    function setL2GatewayRouter(address newL2GatewayRouter) public onlyAdmin nonReentrant {
        _setL2GatewayRouter(newL2GatewayRouter);
    }

    /**
     * @notice Add L2 -> L1 token mapping. Callable only by admin.
     * @param l2Token Arbitrum token.
     * @param l1Token Ethereum version of l2Token.
     */
    function whitelistToken(address l2Token, address l1Token) public onlyAdmin nonReentrant {
        _whitelistToken(l2Token, l1Token);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        // If the l2TokenAddress is UDSC, we need to use the CCTP bridge.
        if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
            _transferUsdc(hubPool, amountToReturn);
        } else {
            // Check that the Ethereum counterpart of the L2 token is stored on this contract.
            address ethereumTokenToBridge = whitelistedTokens[l2TokenAddress];
            require(ethereumTokenToBridge != address(0), "Uninitialized mainnet token");
            //slither-disable-next-line unused-return
            StandardBridgeLike(l2GatewayRouter).outboundTransfer(
                ethereumTokenToBridge, // _l1Token. Address of the L1 token to bridge over.
                hubPool, // _to. Withdraw, over the bridge, to the l1 hub pool contract.
                amountToReturn, // _amount.
                "" // _data. We don't need to send any data for the bridging action.
            );
        }
    }

    function _setL2GatewayRouter(address _l2GatewayRouter) internal {
        l2GatewayRouter = _l2GatewayRouter;
        emit SetL2GatewayRouter(l2GatewayRouter);
    }

    function _whitelistToken(address _l2Token, address _l1Token) internal {
        whitelistedTokens[_l2Token] = _l1Token;
        emit WhitelistedTokens(_l2Token, _l1Token);
    }

    // L1 addresses are transformed during l1->l2 calls.
    // See https://developer.offchainlabs.com/docs/l1_l2_messages#address-aliasing for more information.
    // This cannot be pulled directly from Arbitrum contracts because their contracts are not 0.8.X compatible and
    // this operation takes advantage of overflows, whose behavior changed in 0.8.0.
    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        // Allows overflows as explained above.
        unchecked {
            l2Address = address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
        }
    }

    // Apply AVM-specific transformation to cross domain admin address on L1.
    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}
}
