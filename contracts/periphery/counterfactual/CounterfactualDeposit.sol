// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";
import { IRoutePolicy } from "../../interfaces/IRoutePolicy.sol";
import { CloneArgs, CounterfactualCloneArgs } from "./CounterfactualCloneArgs.sol";

/**
 * @title CounterfactualDeposit
 * @notice Merkle-dispatched entrypoint for counterfactual deposit clones. All clones are EIP-1167
 *         proxies that delegatecall into this dispatcher.
 * @dev The clone's immutable arg is a single 32-byte `argsHash` over the five `CloneArgs` identity
 *      fields. On every execute, the dispatcher:
 *        1. Recomputes the hash from caller-supplied `cloneArgs` and reverts on mismatch.
 *        2. If `msg.sender == cloneArgs.admin`, skips the merkle check (admin escape — admin has
 *           full execution authority over this clone and can call any implementation regardless of
 *           policy state, including when the policy's `activeRoot` is `bytes32(0)`).
 *        3. Otherwise computes the leaf as
 *           `keccak256(bytes.concat(keccak256(abi.encode(implementation, cloneArgs.outputToken, cloneArgs.destinationChainId, keccak256(routeParams)))))`
 *           and verifies the merkle proof against `IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot(address(this))`.
 *           Binding the clone identity into the leaf preimage ensures a leaf can only be proven
 *           against the clone it was authored for.
 *        4. Delegatecalls the implementation, forwarding the dispatcher-verified clone-identity
 *           fields.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDeposit is ICounterfactualDeposit {
    using CounterfactualCloneArgs for CloneArgs;

    /// @dev Accept native ETH sent to the clone (user deposits, refunds, LayerZero fees, etc.).
    receive() external payable {}

    /// @inheritdoc ICounterfactualDeposit
    function execute(
        CloneArgs calldata cloneArgs,
        address implementation,
        bytes calldata routeParams,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable {
        // Verify caller-supplied cloneArgs match the clone's stored hash.
        bytes32 storedHash = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32));
        if (cloneArgs.hash() != storedHash) revert InvalidCloneArgs();

        // Admin escape — admin can execute any implementation, bypassing the policy.
        // Works even if `activeRoot == bytes32(0)` or the policy contract is bricked.
        if (msg.sender != cloneArgs.admin) {
            // Verify merkle proof against the policy's active root. The leaf preimage binds the
            // clone's identity (outputToken, destinationChainId) so a leaf can only be proven against
            // the clone it was authored for — no separate identity check needed.
            bytes32 leaf = keccak256(
                bytes.concat(
                    keccak256(
                        abi.encode(
                            implementation,
                            cloneArgs.outputToken,
                            cloneArgs.destinationChainId,
                            keccak256(routeParams)
                        )
                    )
                )
            );
            bytes32 root = IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot(address(this));
            if (!MerkleProof.verify(proof, root, leaf)) revert InvalidProof();
        }

        // Delegatecall the implementation with the dispatcher-verified clone-identity fields.
        // `recipient`, `outputToken`, `destinationChainId`, and `admin` are forwarded; impls that
        // depend on the admin escape for authorization (e.g. WithdrawImplementation) verify
        // `msg.sender == admin` independently. `routePolicyAddress` stays dispatcher-internal.
        _delegate(implementation, cloneArgs, routeParams, submitterData);
    }

    function _delegate(
        address implementation,
        CloneArgs calldata cloneArgs,
        bytes calldata routeParams,
        bytes calldata submitterData
    ) private {
        (bool success, bytes memory result) = implementation.delegatecall(
            abi.encodeCall(
                ICounterfactualImplementation.execute,
                (
                    cloneArgs.recipient,
                    cloneArgs.outputToken,
                    cloneArgs.destinationChainId,
                    cloneArgs.admin,
                    routeParams,
                    submitterData
                )
            )
        );
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
