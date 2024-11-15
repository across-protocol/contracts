// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

/**
 * @notice Contract containing logic to send messages from L1 to a withdrawal helper or forwarder contract on an L2. This adapter is used to
 * communicate directly with those contracts. While any message can be sent to those contracts with this adapter,
 * it should generally be used to perform upgrades to their proxies.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract L2Admin_Adapter is AdapterInterface {
    // Adapter designed to relay messages from L1 to L2 addresses and delegatecalled by this contract to send messages to the forwarder
    // contract on L2.
    address public immutable L1_ADAPTER;

    error RelayMessageFailed();

    /**
     * @notice Constructs new Adapter. This contract will use the L1_ADAPTER contract to send admin messages to a target on L2.
     * @param _l1Adapter Address of the adapter contract on mainnet which implements message transfers and token relays to the L2
     * where the L2 target is deployed.
     */
    constructor(address _l1Adapter) {
        L1_ADAPTER = _l1Adapter;
    }

    function relayMessage(address, bytes memory message) external payable override {
        (address target, bytes memory _relayMessage) = abi.decode(message, (address, bytes));
        (bool success, ) = L1_ADAPTER.delegatecall(
            abi.encodeCall(AdapterInterface.relayMessage, (target, _relayMessage))
        );
        if (!success) revert RelayMessageFailed();
    }

    function relayTokens(
        address,
        address,
        uint256,
        address
    ) external payable override {
        revert("Cannot relay tokens with the L2Admin_Adapter");
    }
}
