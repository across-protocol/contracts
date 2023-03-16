// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @notice Sends cross chain messages and tokens to contracts on a specific L2 network.
 * This interface is implemented by an adapter contract that is deployed on L1.
 */

interface AdapterInterface {
    event MessageRelayed(address target, bytes message);

    event TokensRelayed(address l1Token, address l2Token, uint256 amount, address to);

    /**
     * @notice Send message to `target` on L2.
     * @dev This method is marked payable because relaying the message might require a fee
     * to be paid by the sender to forward the message to L2. However, it will not send msg.value
     * to the target contract on L2.
     * @param target L2 address to send message to.
     * @param message Message to send to `target`.
     */
    function relayMessage(address target, bytes calldata message) external payable;

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
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable;
}
