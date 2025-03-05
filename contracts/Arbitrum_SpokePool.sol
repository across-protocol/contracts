// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "./libraries/CircleCCTPAdapter.sol";
import "./libraries/OFTTransportAdapter.sol";
import { CrossDomainAddressUtils } from "./libraries/CrossDomainAddressUtils.sol";
import { ArbitrumL2ERC20GatewayLike } from "./interfaces/ArbitrumBridge.sol";

/**
 * @notice AVM specific SpokePool. Uses AVM cross-domain-enabled logic to implement admin only access to functions.
 * @custom:security-contact bugs@across.to
 */
contract Arbitrum_SpokePool is SpokePool, CircleCCTPAdapter, OFTTransportAdapter {
    // Address of the Arbitrum L2 token gateway to send funds to L1.
    address public l2GatewayRouter;

    // Admin controlled mapping of arbitrum tokens to L1 counterpart. L1 counterpart addresses
    // are necessary params used when bridging tokens to L1.
    mapping(address => address) public whitelistedTokens;

    // a map to store token -> IOFT relationships for OFT bridging.
    mapping(IERC20 => IOFT) public oftMessengers;

    event SetL2GatewayRouter(address indexed newL2GatewayRouter);
    event WhitelistedTokens(address indexed l2Token, address indexed l1Token);
    // todo: do we really need this event? Considering we're approaching contract size limits
    event OFTMessengerSet(IERC20 indexed token, IOFT indexed messenger);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        // _oftSaneFeeCap can be set to 0.1 ether for arbitrum, but has to be custom-set for other chains that might use inherit this adapter, like AlephZero
        uint256 _oftSaneFeeCap
    )
        SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer)
        CircleCCTPAdapter(_l2Usdc, _cctpTokenMessenger, CircleDomainIds.Ethereum)
        OFTTransportAdapter(OFTEIds.Ethereum, _oftSaneFeeCap)
    {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the AVM SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _l2GatewayRouter Address of L2 token gateway. Can be reset by admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _withdrawalRecipient Address which receives token withdrawals. Can be changed by admin. For Spoke Pools on L2, this will
     * likely be the hub pool.
     */
    function initialize(
        uint32 _initialDepositId,
        address _l2GatewayRouter,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient);
        _setL2GatewayRouter(_l2GatewayRouter);
    }

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == CrossDomainAddressUtils.applyL1ToL2Alias(crossDomainAdmin), "ONLY_COUNTERPART_GATEWAY");
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

    /**
     * @notice Add token -> OFTMessenger relationship. Callable only by admin.
     * @param token Arbitrum token.
     * @param messenger IOFT contract that acts as OFT mailbox.
     */
    function setOftMessenger(IERC20 token, IOFT messenger) public onlyAdmin nonReentrant {
        _setOftMessenger(token, messenger);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        (IOFT oftMessenger, bool oftEnabled) = _getOftMessenger(IERC20(l2TokenAddress));

        // If the l2TokenAddress is UDSC, we need to use the CCTP bridge.
        if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
            _transferUsdc(withdrawalRecipient, amountToReturn);
        }
        // If OFT is enabled for token, we need to use the OFT bridge.
        else if (oftEnabled) {
            _transferViaOFT(IERC20(l2TokenAddress), oftMessenger, withdrawalRecipient, amountToReturn);
        } else {
            // Check that the Ethereum counterpart of the L2 token is stored on this contract.
            address ethereumTokenToBridge = whitelistedTokens[l2TokenAddress];
            require(ethereumTokenToBridge != address(0), "Uninitialized mainnet token");
            //slither-disable-next-line unused-return
            ArbitrumL2ERC20GatewayLike(l2GatewayRouter).outboundTransfer(
                ethereumTokenToBridge, // _l1Token. Address of the L1 token to bridge over.
                withdrawalRecipient, // _to. Withdraw, over the bridge, to the l1 hub pool contract.
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

    // Apply AVM-specific transformation to cross domain admin address on L1.
    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}

    function _setOftMessenger(IERC20 _token, IOFT _messenger) internal {
        oftMessengers[_token] = _messenger;
        emit OFTMessengerSet(_token, _messenger);
    }

    function _getOftMessenger(IERC20 _token) internal view returns (IOFT messenger, bool oftEnabled) {
        messenger = oftMessengers[_token];
        return (messenger, address(messenger) != address(0));
    }

    // Reserve storage slots for future versions of this base contract to add state variables without
    // affecting the storage layout of child contracts. Decrement the size of __gap whenever state variables
    // are added. This is at bottom of contract to make sure it's always at the end of storage.
    uint256[1000] private __gap;
}
