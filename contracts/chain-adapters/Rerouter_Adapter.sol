// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

/**
 * @notice Contract containing logic to send messages from L1 to non-spoke pool L2 targets via re-routing message recipients
 * before submission. This ultimately enables sending messages to targets on arbitrary layers via forwarding through intermediate
 * contracts.
 * @dev Since this adapter is normally called by the hub pool, the target of both `relayMessage` and `relayTokens`
 * will be the remote spoke pool due to the constraints of `setCrossChainContracts` outlined in UMIP 157. However, this
 * contract cannot send anything directly to the this target, since it does not exist on L2. Instead, it "re-routes"
 * messages to the remote network via intermediate forwarder contracts,beginning with an L2 forwarder, which is set as the
 * `l2Target` in this contract. Each forwarder contract contains logic which determines the path a message or token relay
 * must take to ultimately arrive at the spoke pool. There should be one of these adapters for each L3 spoke pool deployment.
 * @dev All forwarder contracts, including `l2Target`, must implement ForwarderBase in order for tokens and messages to be
 * automatically relayed to the subsequent layers.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Rerouter_Adapter is AdapterInterface {
    address public immutable L1_ADAPTER;
    address public immutable L2_TARGET;

    error RelayMessageFailed();
    error RelayTokensFailed(address l1Token);

    /**
     * @notice Constructs new Adapter for sending tokens/messages to an L2 target. This contract will
     * re-route messages to L2_TARGET via the L1_ADAPTER contract.
     * @param _l1Adapter Address of the adapter contract on mainnet which implements message transfers
     * and token relays.
     * @param _l2Target Address of the L2 contract which receives the token and message relays.
     */
    constructor(address _l1Adapter, address _l2Target) {
        L1_ADAPTER = _l1Adapter;
        L2_TARGET = _l2Target;
    }

    /**
     * @notice Send cross-chain message to a target on L2 which will forward messages to the intended remote target.
     * @param target Address of the remote contract which receives `message` after it has been forwarded by all intermediate
     * contracts.
     * @param message Data to send to `target`.
     * @dev The message passed into this function is wrapped into a `relayMessage` function call, which is then passed
     * to L2. The `L2_TARGET` contract implements AdapterInterface, so upon arrival on L2, the arguments to the L2 contract's
     * `relayMessage` call will be these `target` and `message` values. From there, the forwarder derives the next appropriate
     * method to send `message` to the following layers.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        bytes memory wrappedMessage = abi.encodeCall(AdapterInterface.relayMessage, (target, message));
        (bool success, ) = L1_ADAPTER.delegatecall(
            abi.encodeCall(AdapterInterface.relayMessage, (L2_TARGET, wrappedMessage))
        );
        if (!success) revert RelayMessageFailed();
    }

    /**
     * @notice Bridge tokens to a target on L2 and follow up the token bridge with a call to continue bridging the sent tokens.
     * @param l1Token L1 token to deposit.
     * @param l2Token L2 token to receive.
     * @param amount Amount of L1 tokens to deposit and L2 tokens to receive.
     * @param target The address of the contract which should ultimately receive `amount` of `l1Token`.
     * @dev When sending tokens, we follow-up with a message describing the amount of tokens we wish to continue bridging.
     * This allows forwarders to know how much of some token to allocate to a certain target.
     */
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address target
    ) external payable override {
        // Relay tokens to the forwarder.
        (bool success, ) = L1_ADAPTER.delegatecall(
            abi.encodeCall(AdapterInterface.relayTokens, (l1Token, l2Token, amount, L2_TARGET))
        );
        if (!success) revert RelayTokensFailed(l1Token);

        // Follow-up token relay with a message to continue the token relay on L2.
        bytes memory message = abi.encodeCall(AdapterInterface.relayTokens, (l1Token, l2Token, amount, target));
        (success, ) = L1_ADAPTER.delegatecall(abi.encodeCall(AdapterInterface.relayMessage, (L2_TARGET, message)));
        if (!success) revert RelayMessageFailed();
    }
}
