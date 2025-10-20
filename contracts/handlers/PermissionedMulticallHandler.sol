// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import { MulticallHandler } from "./MulticallHandler.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title PermissionedMulticallHandler
 * @notice Extension of MulticallHandler that restricts access to whitelisted callers
 * @dev Uses OpenZeppelin's AccessControl for caller permission management.
 * Only addresses with the WHITELISTED_CALLER_ROLE can call handleV3AcrossMessage.
 */
contract PermissionedMulticallHandler is MulticallHandler, AccessControl {
    /// @notice Role identifier for whitelisted callers
    bytes32 public constant WHITELISTED_CALLER_ROLE = keccak256("WHITELISTED_CALLER_ROLE");

    /// @notice Emitted when a caller is whitelisted
    event CallerWhitelisted(address indexed caller);

    /// @notice Emitted when a caller is removed from whitelist
    event CallerRemovedFromWhitelist(address indexed caller);

    /// @notice Error thrown when caller is not whitelisted
    error CallerNotWhitelisted(address caller);

    /**
     * @notice Constructor that sets up the initial admin
     * @param admin Address that will have DEFAULT_ADMIN_ROLE
     */
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /**
     * @notice Overrides handleV3AcrossMessage to add caller whitelist check
     * @dev Only addresses with WHITELISTED_CALLER_ROLE can call this function
     * @param token The token being transferred
     * @param amount The amount of tokens
     * @param relayer The relayer address
     * @param message The encoded Instructions struct
     */
    function handleV3AcrossMessage(
        address token,
        uint256 amount,
        address relayer,
        bytes memory message
    ) public override {
        if (!hasRole(WHITELISTED_CALLER_ROLE, msg.sender)) {
            revert CallerNotWhitelisted(msg.sender);
        }

        // Call parent implementation
        super.handleV3AcrossMessage(token, amount, relayer, message);
    }

    /**
     * @notice Add a caller to the whitelist
     * @param caller Address to whitelist
     */
    function whitelistCaller(address caller) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(WHITELISTED_CALLER_ROLE, caller);
        emit CallerWhitelisted(caller);
    }

    /**
     * @notice Remove a caller from the whitelist
     * @param caller Address to remove from whitelist
     */
    function removeCallerFromWhitelist(address caller) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(WHITELISTED_CALLER_ROLE, caller);
        emit CallerRemovedFromWhitelist(caller);
    }
}
