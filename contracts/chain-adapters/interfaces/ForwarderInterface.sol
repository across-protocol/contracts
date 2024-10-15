// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Sends cross chain messages and tokens to contracts on a specific L3 network.
 * This interface is implemented by forwarder contracts deployed to L2s.
 */

interface ForwarderInterface {
    // A TokenRelay defines all the information a forwarder needs to send tokens to an L3.
    struct TokenRelay {
        // The address of the token on L2 to send to L3.
        address l2Token;
        // The address of the token on L3 to receive.
        address l3Token;
        // The L3 address of the recipient.
        address to;
        // The amount of the L2 token to send over the L2-L3 bridge.
        uint256 amount;
        // The chain ID of the L3 to send tokens to.
        uint256 destinationChainId;
        // A yes/no value for determining whether the token relay which was stored has been executed.
        bool executed;
    }

    event MessageForwarded(address indexed target, uint256 indexed chainId, bytes message);
    event TokenRelayReceived(uint32 indexed tokenRelayId, TokenRelay tokenRelay);
    event TokensForwarded(uint32 indexed tokenRelayId);

    /**
     * @notice Send message to `target` on L3.
     * @dev This method is marked payable because relaying the message might require a fee
     * to be paid by the sender to forward the message to L3. However, it will not send msg.value
     * to the target contract on L3.
     * @param target L3 address to send message to.
     * @param destinationChainId Chain ID of the L3 network.
     * @param message Message to send to `target`.
     */
    function relayMessage(
        address target,
        uint256 destinationChainId,
        bytes calldata message
    ) external payable;

    /**
     * @notice Send `amount` of `l2Token` to `to` on L3. `l3oken` is the L3 address equivalent of `l2Token`.
     * @dev This method is marked payable because relaying the message might require a fee
     * to be paid by the sender to forward the message to L2. However, it will not send msg.value
     * to the target contract on L2.
     * @param l2Token L2 token to bridge.
     * @param l3Token L3 token to receive.
     * @param amount Amount of `l2Token` to bridge.
     * @param destinationChainId Chain ID of the L3 network.
     * @param to Bridge recipient.
     */
    function relayTokens(
        address l2Token,
        address l3Token,
        uint256 amount,
        uint256 destinationChainId,
        address to
    ) external payable;

    error RelayMessageFailed();
    error RelayTokensFailed(address l2Token);
    error TokenRelayExecuted();
}
