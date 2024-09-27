// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

/**
 * @notice Contract containing logic to send messages from L1 to a target on L3 via re-routing messages to an
 * intermediate contract on L2.
 * @dev Since this adapter is normally called by the hub pool, the target of both `relayMessage` and `relayTokens`
 * will be the L3 spoke pool due to the constraints of `setCrossChainContracts` outlined in UMIP 157. However, this
 * contract cannot send anything directly to the L3 target. Instead, it "re-routes" messages to the L3 via an L2
 * contract set as the `l2Target` in this contract. The L3 spoke pool address must be initialized on the `l2Target`
 * contract to the same L3 spoke pool address found in the hub pool's `crossChainContracts` mapping. There should be
 * one of these adapters for each L3 spoke pool deployment.
 * @dev The contract set as the l2Target must implement ForwarderBase in order for tokens and messages to be automatically
 * forwarded to the next layers.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Rerouter_Adapter is AdapterInterface {
    address public immutable l1Adapter;
    address public immutable l2Target;
    uint256 public immutable spokePoolChainId;

    error RelayMessageFailed();
    error RelayTokensFailed(address l1Token);

    /**
     * @notice Constructs new Adapter for sending tokens/messages to an L2 target. This contract will
     * re-route messages to the _l2Target via the _l1Adapter.
     * @param _l1Adapter Address of the adapter contract on mainnet which implements message transfers
     * and token relays.
     * @param _l2Target Address of the L2 contract which receives the token and message relays.
     * @param _spokePoolChainId Chain ID of the network which contains this adapter's corresponding spoke pool deployment.
     */
    constructor(
        address _l1Adapter,
        address _l2Target,
        uint256 _spokePoolChainId
    ) {
        l1Adapter = _l1Adapter;
        l2Target = _l2Target;
        spokePoolChainId = _spokePoolChainId;
    }

    /**
     * @notice Send cross-chain message to a target on L2 which will re-route messages to the intended L3 target.
     * @param target Address of the L3 contract which receives `message` after it has been forwarded on L2.
     * @param message Data to send to `target`.
     * @dev The message passed into this function is wrapped into a `relayMessage` function call, which is then passed
     * to L2. The l2Target contract implements AdapterInterface, so upon arrival on L2, the arguments to the L2 contract's
     * `relayMessage` call will be these target and message values. When sending a message, `spokePoolChainId` is abi-encoded
     * to provide the forwarder with the necessary information to determine subsequent bridge routes.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        bytes memory updatedMessage = abi.encode(
            spokePoolChainId,
            abi.encodeCall(AdapterInterface.relayMessage, (target, message))
        );
        (bool success, ) = l1Adapter.delegatecall(
            abi.encodeCall(AdapterInterface.relayMessage, (l2Target, updatedMessage))
        );
        if (!success) revert RelayMessageFailed();
    }

    /**
     * @notice Bridge tokens to a target on L2.
     * @param l1Token L1 token to deposit.
     * @param l2Token L2 token to receive.
     * @param amount Amount of L1 tokens to deposit and L2 tokens to receive.
     * @param target The address of the spoke pool which should ultimately receive `amount` of `l1Token`.
     * @dev When sending a message, `spokePoolChainId` is abi-encoded to provide the forwarder with the necessary information
     * to determine subsequent bridge routes.
     */
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address target
    ) external payable override {
        // Relay tokens to the forwarder.
        (bool success, ) = l1Adapter.delegatecall(
            abi.encodeCall(AdapterInterface.relayTokens, (l1Token, l2Token, amount, l2Target))
        );
        if (!success) revert RelayTokensFailed(l1Token);

        // Follow-up token relay with a message to continue the token relay on L2.
        bytes memory message = abi.encode(
            spokePoolChainId,
            abi.encodeCall(AdapterInterface.relayTokens, (l1Token, l2Token, amount, target))
        );
        (success, ) = l1Adapter.delegatecall(abi.encodeCall(AdapterInterface.relayMessage, (l2Target, message)));
        if (!success) revert RelayMessageFailed();
    }
}
