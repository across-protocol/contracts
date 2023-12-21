// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "@scroll-tech/contracts/L2/gateways/IL2GatewayRouter.sol";

contract Scroll_SpokePool is SpokePool {
    IL2GatewayRouter public l2GatewayRouter;

    /**************************************
     *               EVENTS               *
     **************************************/

    event ScrollTokensBridged(address indexed token, address indexed receiver, uint256 amount);

    /**************************************
     *          PUBLIC FUNCTIONS          *
     **************************************/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the Scroll SpokePool.
     * @param _l2GatewayRouter Standard bridge contract.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     */
    function initialize(
        IL2GatewayRouter _l2GatewayRouter,
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool);
        l2GatewayRouter = _l2GatewayRouter;
    }

    /**************************************
     *         INTERNAL FUNCTIONS         *
     **************************************/

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal virtual override {
        IL2GatewayRouter _l2GatewayRouter = l2GatewayRouter;

        // The scroll bridge handles arbitrary ERC20 tokens and is mindful of
        // the official WETH address on-chain. We don't need to do anything specific
        // to differentiate between WETH and a separate ERC20.
        // Note: This happens due to the L2GatewayRouter.getERC20Gateway() call
        _l2GatewayRouter.withdrawERC20{ value: msg.value }(l2TokenAddress, hubPool, amountToReturn, 0);
        emit ScrollTokensBridged(l2TokenAddress, hubPool, amountToReturn);
    }

    function _requireAdminSender() internal view override {
        require(msg.sender == crossDomainAdmin, "Sender must be admin");
    } // solhint-disable-line no-empty-blocks
}
