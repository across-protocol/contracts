// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/// @dev Step is the root of a Merkle tree of possible Paths this order can follow.
type Step is bytes32;

/// @dev One of the ways to complete a Step. A Merkle leaf on the Step's root.
///      `chainId` binds the path to a specific chain — Gateway rejects paths
///      whose `chainId` does not match `block.chainid`.
struct Path {
    // Chain this path is intended to execute on
    uint256 chainId;
    // Used for obfuscation of Merkle leaves
    bytes32 salt;
    // Contract to call as bytes32
    bytes32 executor;
    // Message for the executor
    bytes message;
}

/// @notice A funding entry. `header` packs (commitmentLevel << 8 | typ); see
///         `FundingCodec.{packHeader,unpackHeader}` and the FUNDING_* /
///         COMMITMENT_* constants in `GatewayFunding.sol`. `commitmentLevel` is
///         ignored for FUNDING_TRANSFER_FROM (no witness).
struct FundingEntry {
    uint256 header;
    bytes data;
}

struct SubmitterInputs {
    Path path;
    // Always a Merkle proof — single-path steps use a one-leaf tree with an empty proof.
    bytes32[] proof;
    // Note: when interpreting path.message provided by the user, path.executor will sometimes reach into executorMessage
    // provided here for submitter-provided data. User defines commands + static values, this lets submitter augment
    // execution with dynamic data (e.g. planner output or DEX swap instructions)
    bytes executorMessage;
}

/// @notice Live execution context exposed by Gateway during each execution.
struct ExecutionContext {
    bytes32 pathId;
    address submitter;
}

/// @notice Deposit parameters the Executor ABI-encodes into the `input` payload of `adapterExecuteAcrossV5`.
struct ParamsFromV5Input {
    bytes32 depositor;
    bytes32 recipient;
    bytes32 inputToken;
    bytes32 outputToken;
    uint256 inputAmount;
    uint256 outputAmount;
    uint256 destinationChainId;
    bytes32 exclusiveRelayer;
    uint256 depositNonce;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 exclusivityParameter;
    bytes32 dstStepId;
    // Deposit modification rules. Packing: (high 12 bytes for modify permisison flags, low 20 bytes for signing authority if required)
    // Current flags: bit 0: outputAmount, bit 1: exclusiveRelayer, bit 2: exclusivityParameter
    bytes32 paramModificationRules;
}

/// @notice Just-in-time modification values the Executor ABI-encodes into the `jitData` payload of
/// `adapterExecuteAcrossV5`, applied subject to `ParamsFromV5Input.paramModificationRules`.
struct ParamsFromV5Jit {
    uint256 newAmtOut;
    bytes32 newExclusiveRelayer;
    uint32 newExclusivityParameter;
    bytes signature;
}
