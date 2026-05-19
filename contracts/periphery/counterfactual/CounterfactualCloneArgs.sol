// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Identity fields hashed into each clone's immutable argument.
 * @dev Stored on-chain as a single 32-byte `argsHash`; the dispatcher recomputes the hash from
 *      caller-supplied fields at execute time and reverts on mismatch.
 * @param outputToken Token received on the destination chain (bytes32 to support non-EVM tokens).
 * @param destinationChainId Destination chain ID (or canonical Across ID for non-EVM destinations).
 * @param recipient Destination-chain address that receives `outputToken`.
 * @param withdrawUser EVM address authorized to invoke the structural withdraw escape.
 * @param routePolicyAddress `RoutePolicy` contract whose root authorizes this clone's routes.
 */
struct CloneArgs {
    bytes32 outputToken;
    uint256 destinationChainId;
    bytes32 recipient;
    address withdrawUser;
    address routePolicyAddress;
}

/**
 * @title CounterfactualCloneArgs
 * @notice Canonical hashing helper for `CloneArgs`. The factory uses it to compute the clone's
 *         immutable-args blob; the dispatcher uses it to verify caller-supplied args at execute time.
 *         Both must agree on the layout, hence the single shared helper.
 */
library CounterfactualCloneArgs {
    function hash(CloneArgs memory args) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    args.outputToken,
                    args.destinationChainId,
                    args.recipient,
                    args.withdrawUser,
                    args.routePolicyAddress
                )
            );
    }
}
