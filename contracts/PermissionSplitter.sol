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
        uint32 liveness; // The minimum time between a proposal being made and executed.
        uint8 tier;
    }

    struct Proposal {
        address target;
        bytes32 functionSig;
        bytes functionCallData;
        ProposalStatus status;
        uint256 proposalTime;
    }

    // UUID for proposals.
    uint256 public nonce;

    // Tracks proposed proposals that passed quorum and can be executed after liveness.
    mapping(uint256 => Proposal) public proposals;

    // Maps function signatures to permission tiers, making it convenient to batch change params for multiple
    // functions.
    mapping(bytes32 => uint8) public permissionTierForFunctionSig;

    // Maps permission tiers to their configuration.
    mapping(uint8 => PermissionsTier) public permissionsTiers;

    function setPermissionTier(uint8 tier, uint32 liveness) external onlyRole(DEFAULT_ADMIN_ROLE) {
        permissionsTiers[tier] = PermissionsTier({ liveness: liveness, tier: tier });
    }

    // Only callable by someone who has correct role for the function sig they want to call.
    function proposeAction(
        bytes32 functionSig,
        bytes memory functionCallData,
        address target
    ) external onlyRole(functionSig) {
        proposals[nonce] = Proposal({
            target: target,
            functionSig: functionSig,
            functionCallData: functionCallData,
            status: ProposalStatus.Pending,
            proposalTime: block.timestamp
        });
        nonce++;
    }

    // Can execute pending proposal after liveness period has elapsed.
    function executeAction(uint256 proposalId) external {
        // Need to handle fact that livenesses can change after a proposal is pending...
        uint256 livenessForProposal = permissionsTiers[permissionTierForFunctionSig[proposals[proposalId].functionSig]]
            .liveness;
        require(
            block.timestamp >= proposals[proposalId].proposalTime + livenessForProposal,
            "Cannot execute proposal until liveness period has elapsed."
        );
        proposals[nonce].status = ProposalStatus.Executed;
        // Execute the action...
    }
}
