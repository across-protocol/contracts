// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IUpgradeRegistry } from "../../interfaces/IUpgradeRegistry.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CounterfactualBase } from "./CounterfactualBase.sol";

/**
 * @title CounterfactualDeposit
 * @notice The real (upgradeable) implementation a counterfactual proxy runs after finalize — the
 *         merkle-dispatched entry point. Verifies a leaf against `activeRoot`, then delegatecalls the
 *         per-bridge implementation the leaf authorizes (which decodes the destination identity from
 *         `params` and performs the bridge deposit).
 * @dev Set as the registry's `currentImplementation`. Holds no per-route state; identity/routes live in
 *      the `activeRoot` tree. Runs under the proxy via UUPS, so `address(this)` is the proxy throughout
 *      (correct for EIP-712 domains and token balances), `msg.sender` is the original caller, and
 *      `msg.value` is the original value.
 *
 *      Note: some leaf implementations use authorization signatures that cover execution-time
 *      parameters (amounts, deadlines) but not the leaf's route `params`. If two leaves share the same
 *      implementation address, a caller could prove leaf A's params while submitting a signature meant
 *      for leaf B. A clone's tree must therefore never contain multiple leaves with the same
 *      implementation address.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDeposit is CounterfactualBase, ICounterfactualDeposit {
    constructor(IUpgradeRegistry registry) CounterfactualBase(registry) {}

    /// @dev Accept native value sent to the proxy (deposits before/after deployment, refunds).
    receive() external payable {}

    /// @inheritdoc ICounterfactualDeposit
    function execute(
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable {
        // Double-hash to prevent leaf/internal-node ambiguity (OpenZeppelin standard).
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))));
        if (!MerkleProof.verify(proof, activeRoot(), leaf)) revert InvalidProof();

        (bool success, bytes memory result) = implementation.delegatecall(
            abi.encodeCall(ICounterfactualImplementation.execute, (params, submitterData))
        );
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
