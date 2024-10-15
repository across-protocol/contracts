// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

/**
 * @notice Contract containing logic to send messages from L1 to a withdrawal helper contract on an L2. This adapter is used to
 * communicate directly with a withdrawal helper. While any message can be sent to the withdrawal helper with this contract,
 * it should generally be used to perform upgrades to the withdrawal helper proxy.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract WithdrawalHelperAdmin_Adapter is AdapterInterface {
    // Adapter designed to relay messages from L1 to L2 addresses and delegatecalled by this contract to send messages to the forwarder
    // contract on L2.
    address public immutable L1_ADAPTER;
    // Address of the withdrawal helper contract on L2. This is the value which overwrites the hub pool's supplied value in `relayMessage`.
    address public immutable WITHDRAWAL_HELPER;

    error RelayMessageFailed();

    /**
     * @notice Constructs new Adapter. This contract will use the L1_ADAPTER contract to send admin messages to `WITHDRAWAL_HELPER` on L2.
     * @param _l1Adapter Address of the adapter contract on mainnet which implements message transfers and token relays to the L2
     * where _forwarder is deployed.
     * @param _withdrawalHelper Address of the withdrawal helper contract on L2 which receives the admin messages.
     */
    constructor(address _l1Adapter, address _withdrawalHelper) {
        L1_ADAPTER = _l1Adapter;
        WITHDRAWAL_HELPER = _withdrawalHelper;
    }

    function relayMessage(address, bytes memory message) external payable override {
        (bool success, ) = L1_ADAPTER.delegatecall(
            abi.encodeCall(AdapterInterface.relayMessage, (WITHDRAWAL_HELPER, message))
        );
        if (!success) revert RelayMessageFailed();
    }

    function relayTokens(
        address,
        address,
        uint256,
        address
    ) external payable override {
        revert("Cannot relay tokens to a withdrawal helper");
    }
}
