// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Identity fields hashed into each clone's immutable argument.
 * @dev Stored on-chain as a single 32-byte `argsHash`; the dispatcher recomputes the hash from
 *      caller-supplied fields at execute time and reverts on mismatch.
 * @param outputToken Token received on the destination chain (bytes32 to support non-EVM tokens).
 * @param destinationChainId Destination chain ID (or canonical Across ID for non-EVM destinations).
 * @param recipient Destination-chain address that receives `outputToken`.
 * @param userAddress EVM address representing the clone's user — the canonical authority and the
 *                    sole destination for withdrawals. The dispatcher's admin escape lets this
 *                    address call any implementation directly (bypassing the policy's merkle-proof
 *                    requirement); `WithdrawImplementation` always sends withdrawn funds here,
 *                    independent of who triggered the withdrawal.
 * @param routePolicyAddress `RoutePolicy` contract whose root authorizes this clone's routes.
 */
struct CloneArgs {
    bytes32 outputToken;
    uint256 destinationChainId;
    bytes32 recipient;
    address userAddress;
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
                    args.userAddress,
                    args.routePolicyAddress
                )
            );
    }
}
