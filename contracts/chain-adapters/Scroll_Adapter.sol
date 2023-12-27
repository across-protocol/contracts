// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@scroll-tech/contracts/L1/gateways/IL1GatewayRouter.sol";
import "@scroll-tech/contracts/L1/rollup/IL2GasPriceOracle.sol";
import "@scroll-tech/contracts/L1/IL1ScrollMessenger.sol";
import "./interfaces/AdapterInterface.sol";

/**
 * @title Scroll_Adapter
 * @notice Adapter contract deployed on L1 alongside the HubPool to facilitate token transfers
 * and arbitrary message relaying from L1 to L2.
 */
contract Scroll_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;
    uint32 public immutable l2GasLimit = 250_000;

    IL1GatewayRouter public immutable l1GatewayRouter;
    IL1ScrollMessenger public immutable l1ScrollMessenger;
    IL2GasPriceOracle public immutable l2GasPriceOracle;

    /**
     * @notice Constructs new Adapter.
     * @param _l1GatewayRouter Standard bridge contract.
     * @param _l1ScrollMessenger Scroll Messenger contract.
     * @param _l2GasPriceOracle Gas price oracle contract.
     */
    constructor(
        IL1GatewayRouter _l1GatewayRouter,
        IL1ScrollMessenger _l1ScrollMessenger,
        IL2GasPriceOracle _l2GasPriceOracle
    ) {
        l1GatewayRouter = _l1GatewayRouter;
        l1ScrollMessenger = _l1ScrollMessenger;
        l2GasPriceOracle = _l2GasPriceOracle;
    }

    /**
     * @notice Generates the relayer fee for a message to be sent to L2.
     */
    function _generateRelayerFee() internal view returns (uint256) {
        return l2GasPriceOracle.estimateCrossDomainMessageFee(l2GasLimit);
    }

    /**
     * @notice Send message to `target` on Scroll.
     * @dev This message is marked payable because relaying the message will require
     * a fee that needs to be propagated to the Scroll Bridge. It will not send msg.value
     * to the target contract on L2.
     * @param target L2 address to send message to.
     * @param message Message to send to `target`.
     */
    function relayMessage(address target, bytes calldata message) external payable {
        // We can specifically send a message with 0 value to the Scroll Bridge
        // and it will not forward any ETH to the target contract on L2. However,
        // we need to set the payable value to msg.value to ensure that the Scroll
        // Bridge has enough gas to forward the message to L2.
        l1ScrollMessenger.sendMessage{ value: _generateRelayerFee() }(target, 0, message, l2GasLimit);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Send `amount` of `l1Token` to `to` on Scroll. `l2Token` is the Scroll address equivalent of `l1Token`.
     * @dev This method is marked payable because relaying the message might require a fee
     * to be paid by the sender to forward the message to L2. However, it will not send msg.value
     * to the target contract on L2.
     * @param l1Token L1 token to bridge.
     * @param l2Token L2 token to receive.
     * @param amount Amount of `l1Token` to bridge.
     * @param to Bridge recipient.
     */
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable {
        IL1GatewayRouter _l1GatewayRouter = l1GatewayRouter;

        // Confirm that the l2Token that we're trying to send is the correct counterpart
        // address
        address _l2Token = _l1GatewayRouter.getL2ERC20Address(l1Token);
        require(_l2Token == l2Token, "l2Token Mismatch");

        // Bump the allowance
        IERC20(l1Token).safeIncreaseAllowance(address(_l1GatewayRouter), amount);

        // The scroll bridge handles arbitrary ERC20 tokens and is mindful of
        // the official WETH address on-chain. We don't need to do anything specific
        // to differentiate between WETH and a separate ERC20.
        // Note: This happens due to the L1GatewayRouter.getERC20Gateway() call
        _l1GatewayRouter.depositERC20{ value: _generateRelayerFee() }(l1Token, to, amount, l2GasLimit);
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
