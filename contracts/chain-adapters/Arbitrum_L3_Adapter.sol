// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

/**
 * @notice Contract containing logic to send messages from L1 to Arbitrum-like L3s using an intermediate L2 message forwarder.
 * @notice This contract requires an L2 forwarder contract to be deployed, since we overwrite the target field to this new target.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_L3_Adapter is AdapterInterface {
    address public immutable adapter;
    address public immutable l2Forwarder;

    error RelayMessageFailed();
    error RelayTokensFailed(address l1Token);

    /**
     * @notice Constructs new Adapter for sending tokens/messages to Arbitrum-like L3s.
     * @param _adapter Address of the adapter contract on mainnet which implements message transfers
     * and token relays.
     * @param _l2Forwarder Address of the l2 forwarder contract which relays messages up to the L3 spoke pool.
     */
    constructor(address _adapter, address _l2Forwarder) {
        adapter = _adapter;
        l2Forwarder = _l2Forwarder;
    }

    /**
     * @notice Send cross-chain message to target on L2, which is forwarded to the Arbitrum-like L3.
     * @dev there is a bijective mapping of L3 adapters (on L1) to L2 forwarders to L3 spoke pools. The
     * spoke pool address is stored by the L2 forwarder and the L2 forwarder address is stored in this contract.
     * @param message Data to send to target.
     */
    function relayMessage(address, bytes memory message) external payable override {
        (bool success, ) = adapter.delegatecall(abi.encodeCall(AdapterInterface.relayMessage, (l2Forwarder, message)));
        if (!success) revert RelayMessageFailed();
    }

    /**
     * @notice Bridge tokens to an Arbitrum-like L3, using an L2 forwarder.
     * @param l1Token L1 token to deposit.
     * @param l2Token L2 token to receive.
     * @param amount Amount of L1 tokens to deposit and L2 tokens to receive.
     * @dev we discard the "to" field since tokens are always sent to the l2Forwarder.
     */
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address
    ) external payable override {
        (bool success, ) = adapter.delegatecall(
            abi.encodeCall(AdapterInterface.relayTokens, (l1Token, l2Token, amount, l2Forwarder))
        );
        if (!success) revert RelayTokensFailed(l1Token);
    }
}
