//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

abstract contract HyperCoreFlowRoles {
    bytes32 public constant PERMISSIONED_BOT_ROLE = keccak256("PERMISSIONED_BOT_ROLE");
    bytes32 public constant FUNDS_SWEEPER_ROLE = keccak256("FUNDS_SWEEPER_ROLE");
}
