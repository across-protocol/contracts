// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "@scroll-tech/contracts/L2/gateways/IL2GatewayRouter.sol";
import "@scroll-tech/contracts/libraries/IScrollMessenger.sol";

interface IL2GatewayRouterExtended is IL2GatewayRouter {
    function defaultERC20Gateway() external view returns (address);

    function getERC20Gateway(address) external view returns (address);
}

/**
 * @title Scroll_SpokePool
 * @notice Modified SpokePool contract deployed on Scroll to facilitate token transfers
 * from Scroll to the HubPool
 * @custom:security-contact bugs@across.to
 */
contract Scroll_SpokePool is SpokePool {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @notice The address of the official l2GatewayRouter contract for Scroll for bridging tokens from L2 -> L1
     * @dev We can find these (main/test)net deployments here: https://docs.scroll.io/en/developers/scroll-contracts/#scroll-contracts
     */
    IL2GatewayRouterExtended public l2GatewayRouter;

    /**
     * @notice The address of the official messenger contract for Scroll from L2 -> L1
     * @dev We can find these (main/test)net deployments here: https://docs.scroll.io/en/developers/scroll-contracts/#scroll-contracts
     */
    IScrollMessenger public l2ScrollMessenger;

    /**************************************
     *               EVENTS               *
     **************************************/

    event SetL2GatewayRouter(address indexed newGatewayRouter, address oldGatewayRouter);
    event SetL2ScrollMessenger(address indexed newScrollMessenger, address oldScrollMessenger);

    /**************************************
     *          PUBLIC FUNCTIONS          *
     **************************************/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    )
        SpokePool(
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            // Scroll_SpokePool does not use OFT messaging, setting destination id and fee cap to 0
            0,
            0
        )
    {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the Scroll SpokePool.
     * @param _l2GatewayRouter Standard bridge contract.
     * @param _l2ScrollMessenger Scroll Messenger contract on L2.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _withdrawalRecipient Address which receives token withdrawals. Can be changed by admin. For Spoke Pools on L2, this will
     * likely be the hub pool.
     */
    function initialize(
        IL2GatewayRouterExtended _l2GatewayRouter,
        IScrollMessenger _l2ScrollMessenger,
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient);
        _setL2GatewayRouter(_l2GatewayRouter);
        _setL2MessageService(_l2ScrollMessenger);
    }

    /**
     * @notice Change the L2 Gateway Router. Changed only by admin.
     * @param _l2GatewayRouter New address of L2 gateway router.
     */
    function setL2GatewayRouter(IL2GatewayRouterExtended _l2GatewayRouter) public onlyAdmin nonReentrant {
        _setL2GatewayRouter(_l2GatewayRouter);
    }

    /**
     * @notice Change L2 message service address. Callable only by admin.
     * @param _l2ScrollMessenger New address of L2 messenger.
     */
    function setL2ScrollMessenger(IScrollMessenger _l2ScrollMessenger) public onlyAdmin nonReentrant {
        _setL2MessageService(_l2ScrollMessenger);
    }

    /**************************************
     *         INTERNAL FUNCTIONS         *
     **************************************/

    /**
     * @notice Bridge tokens to the HubPool.
     * @param amountToReturn Amount of tokens to bridge to the HubPool.
     * @param l2TokenAddress Address of the token to bridge.
     */
    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal virtual override {
        // Tokens with a custom ERC20 gateway require an approval in order to withdraw.
        address erc20Gateway = l2GatewayRouter.getERC20Gateway(l2TokenAddress);
        if (erc20Gateway != l2GatewayRouter.defaultERC20Gateway()) {
            IERC20Upgradeable(l2TokenAddress).safeIncreaseAllowance(erc20Gateway, amountToReturn);
        }

        // The scroll bridge handles arbitrary ERC20 tokens and is mindful of the official WETH address on-chain.
        // We don't need to do anything specific to differentiate between WETH and a separate ERC20.
        // Note: This happens due to the L2GatewayRouter.getERC20Gateway() call
        l2GatewayRouter.withdrawERC20(
            l2TokenAddress,
            withdrawalRecipient,
            amountToReturn,
            // This is the gasLimit for the L2 -> L1 transaction. We don't need to set it.
            // Scroll official docs say it's for compatibility reasons.
            // See: https://github.com/scroll-tech/scroll/blob/0a8164ee5b63ed5d3bd5e7b39d91445a3176e142/contracts/src/L2/gateways/IL2ERC20Gateway.sol#L69-L80
            0
        );
    }

    /**
     * @notice Verifies that calling method is from the cross domain admin.
     */
    function _requireAdminSender() internal view override {
        // The xdomainMessageSender is set within the Scroll messenger right
        // before the call to this function (and reset afterwards). This represents
        // the address that sent the message from L1 to L2. If the calling contract
        // isn't the Scroll messenger, then the xdomainMessageSender will be the zero
        // address and *NOT* cross domain admin.
        address _xDomainSender = l2ScrollMessenger.xDomainMessageSender();
        require(_xDomainSender == crossDomainAdmin, "Sender must be admin");
    }

    function _setL2GatewayRouter(IL2GatewayRouterExtended _l2GatewayRouter) internal {
        address oldL2GatewayRouter = address(l2GatewayRouter);
        l2GatewayRouter = _l2GatewayRouter;
        emit SetL2GatewayRouter(address(_l2GatewayRouter), oldL2GatewayRouter);
    }

    function _setL2MessageService(IScrollMessenger _l2ScrollMessenger) internal {
        address oldL2ScrollMessenger = address(l2ScrollMessenger);
        l2ScrollMessenger = _l2ScrollMessenger;
        emit SetL2ScrollMessenger(address(_l2ScrollMessenger), oldL2ScrollMessenger);
    }
}
