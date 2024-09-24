// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

/**
 * @notice Contract containing logic to send messages from L1 to a target (not necessarily a spoke pool) on L2.
 * @notice Since this adapter is normally called by the hub pool, the target of both `relayMessage` and `relayTokens`
 * will be the L3 spoke pool due to the constraints of `setCrossChainContracts` outlined in UMIP 157. However, this
 * contract DOES NOT send anything to the L2 containing info on the target L3 spoke pool. The L3 spoke pool address
 * must instead be initialized on the `l2Target` contract as the same spoke pool address found in the hub pool's
 * `crossChainContracts` mapping.
 * @notice There should be one of these adapters for each L3 spoke pool deployment, or equivalently, each L2
 * forwarder/adapter contract.
 * @notice The contract receiving messages on L2 will be "spoke pool like" functions, e.g. "relayRootBundle" and
 * "relaySpokePoolAdminFunction".
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

    error RelayMessageFailed();
    error RelayTokensFailed(address l1Token);

    /**
     * @notice Constructs new Adapter for sending tokens/messages to an L2 target.
     * @param _l1Adapter Address of the adapter contract on mainnet which implements message transfers
     * and token relays.
     * @param _l2Target Address of the L2 contract which receives the token and message relays.
     */
    constructor(address _l1Adapter, address _l2Target) {
        l1Adapter = _l1Adapter;
        l2Target = _l2Target;
    }

    /**
     * @notice Send cross-chain message to a target on L2.
     * @notice The original target field is omitted since messages are unconditionally sent to `l2Target`.
     * @param message Data to send to target.
     */
    function relayMessage(address, bytes memory message) external payable override {
        (bool success, ) = l1Adapter.delegatecall(abi.encodeCall(AdapterInterface.relayMessage, (l2Target, message)));
        if (!success) revert RelayMessageFailed();
    }

    /**
     * @notice Bridge tokens to a target on L2.
     * @param l1Token L1 token to deposit.
     * @param l2Token L2 token to receive.
     * @param amount Amount of L1 tokens to deposit and L2 tokens to receive.
     * @notice the "to" field is discarded since we unconditionally relay tokens to `l2Target`.
     */
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address
    ) external payable override {
        (bool success, ) = l1Adapter.delegatecall(
            abi.encodeCall(AdapterInterface.relayTokens, (l1Token, l2Token, amount, l2Target))
        );
        if (!success) revert RelayTokensFailed(l1Token);
    }
}
