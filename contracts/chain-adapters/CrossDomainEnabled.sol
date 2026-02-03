// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/* Interface Imports */
import { ICrossDomainMessenger } from "@eth-optimism/contracts/libraries/bridge/ICrossDomainMessenger.sol";

/**
 * @title CrossDomainEnabled
 * @custom:security-contact bugs@across.to
 * @dev Helper contract for contracts performing cross-domain communications between L1 and Optimism.
 * @dev This modifies the eth-optimism/CrossDomainEnabled contract only by changing state variables to be
 * immutable for use in contracts like the Optimism_Adapter which use delegateCall().
 */
contract CrossDomainEnabled {
    // Messenger contract used to send and receive messages from the other domain.
    address public immutable MESSENGER;

    /**
     * @param _messenger Address of the CrossDomainMessenger on the current layer.
     */
    constructor(address _messenger) {
        MESSENGER = _messenger;
    }

    /**
     * Gets the messenger, usually from storage. This function is exposed in case a child contract
     * needs to override.
     * @return The address of the cross-domain messenger contract which should be used.
     */
    function getCrossDomainMessenger() internal virtual returns (ICrossDomainMessenger) {
        return ICrossDomainMessenger(MESSENGER);
    }

    /**
     * Sends a message to an account on another domain
     * @param _crossDomainTarget The intended recipient on the destination domain
     * @param _gasLimit The gasLimit for the receipt of the message on the target domain.
     * @param _message The data to send to the target (usually calldata to a function with
     *  onlyFromCrossDomainAccount())
     */
    function sendCrossDomainMessage(
        address _crossDomainTarget,
        uint32 _gasLimit,
        bytes calldata _message
    ) internal {
        // slither-disable-next-line reentrancy-events, reentrancy-benign
        getCrossDomainMessenger().sendMessage(_crossDomainTarget, _message, _gasLimit);
    }
}
