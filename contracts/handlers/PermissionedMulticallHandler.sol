// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import { MulticallHandler } from "./MulticallHandler.sol";
import { AccessControl } from "@openzeppelin/contracts-v4/access/AccessControl.sol";

/**
 * @title PermissionedMulticallHandler
 * @notice Extension of MulticallHandler that restricts access to whitelisted callers
 * @dev Uses OpenZeppelin's AccessControl for caller permission management.
 * Only addresses with the WHITELISTED_CALLER_ROLE can call handleV3AcrossMessage.
 */
contract PermissionedMulticallHandler is MulticallHandler, AccessControl {
    /// @notice Role identifier for whitelisted callers
    bytes32 public constant WHITELISTED_CALLER_ROLE = keccak256("WHITELISTED_CALLER_ROLE");

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
    ) public override onlyRole(WHITELISTED_CALLER_ROLE) {
        // Call parent implementation
        super.handleV3AcrossMessage(token, amount, relayer, message);
    }
}
