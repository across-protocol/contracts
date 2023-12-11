// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@scroll-tech/contracts/L1/gateways/IL1GatewayRouter.sol";
import "@scroll-tech/contracts/L1/IL1ScrollMessenger.sol";

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

contract ScrollAdapter is AdapterInterface {
    using SafeERC20 for IERC20;
    uint32 public immutable l2GasLimit = 200_000;

    WETH9Interface public immutable l1Weth;

    IL1GatewayRouter public immutable l1GatewayRouter;
    IL1ScrollMessenger public immutable l1ScrollMessenger;

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _l1GatewayRouter Standard bridge contract.
     * @param _l1ScrollMessenger Scroll Messenger contract.
     */
    constructor(WETH9Interface _l1Weth, IL1GatewayRouter _l1GatewayRouter, IL1ScrollMessenger _l1ScrollMessenger) {
        l1Weth = _l1Weth;
        l1GatewayRouter = _l1GatewayRouter;
        l1ScrollMessenger = _l1ScrollMessenger;
    }

    /**
     * @notice Send message to `target` on L2.
     * @dev This method is marked payable because relaying the message might require a fee
     * to be paid by the sender to forward the message to L2. However, it will not send msg.value
     * to the target contract on L2.
     * @param target L2 address to send message to.
     * @param message Message to send to `target`.
     */
    function relayMessage(address target, bytes calldata message) external payable {
        l1ScrollMessenger.sendMessage(target, msg.value, message, l2GasLimit);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Send `amount` of `l1Token` to `to` on L2. `l2Token` is the L2 address equivalent of `l1Token`.
     * @dev This method is marked payable because relaying the message might require a fee
     * to be paid by the sender to forward the message to L2. However, it will not send msg.value
     * to the target contract on L2.
     * @param l1Token L1 token to bridge.
     * @param l2Token L2 token to receive.
     * @param amount Amount of `l1Token` to bridge.
     * @param to Bridge recipient.
     */
    function relayTokens(address l1Token, address l2Token, uint256 amount, address to) external payable {
        IL1GatewayRouter _l1GatewayRouter = l1GatewayRouter;
        // If the l1Token is weth then unwrap it to ETH then send the ETH to the standard bridge.
        if (l1Token == address(l1Weth)) {
            l1Weth.withdraw(amount);
            _l1GatewayRouter.depositETH(to, amount, l2GasLimit);
        } else {
            IERC20(l1Token).safeIncreaseAllowance(address(_l1GatewayRouter), amount);
            _l1GatewayRouter.depositERC20(l2Token, to, amount, l2GasLimit);
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
