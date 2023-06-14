// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract PermissionSplitter is AccessControl, MultiCaller {
    enum ProposalStatus {
        None,
        Pending,
        Executed
    }

    struct PermissionsTier {
        bytes32 role;
        uint32 liveness; // The minimum time between a proposal being made and executed.
        uint8 minApprovals; // i.e. quorum amongst role members required to execute anything.
        uint8 tier;
    }

    struct Proposal {
        address target;
        bytes32 functionSig;
        bytes params;
        ProposalStatus status;
    }

    // UUID for proposals.
    uint256 nonce;

    // Tracks proposed proposals that passed quorum and can be executed after liveness.
    mapping(uint256 => Proposal) public proposals;

    // Maps function signatures to permission tiers, making it convenient to change params en masse to different
    // functions.
    mapping(bytes32 => uint8) public permissionTierForFunctionSig;

    // Maps permission tiers to their configuration.
    mapping(uint8 => PermissionsTier) public permissionsTiers;

    // General dictionary where admin can associate variables with specific L1 tokens, like the Rate Model and Token
    // Transfer Thresholds.
    mapping(address => string) public l1TokenConfig;

    // General dictionary where admin can store global variables like `MAX_POOL_REBALANCE_LEAF_SIZE` and
    // `MAX_RELAYER_REPAYMENT_LEAF_SIZE` that off-chain agents can query.
    mapping(bytes32 => string) public globalConfig;
}
