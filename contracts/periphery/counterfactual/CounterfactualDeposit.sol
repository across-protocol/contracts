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
 *        2. If `implementation == WITHDRAW_IMPL && msg.sender == cloneArgs.withdrawUser`, skips the
 *           merkle check (structural withdraw escape — works even if the policy is bricked).
 *        3. Otherwise verifies the leaf's first two fields `(destinationChainId, outputToken)` against
 *           `cloneArgs`, then verifies the merkle proof against
 *           `RoutePolicy(cloneArgs.routePolicyAddress).activeRoot()`.
 *        4. Delegatecalls the implementation forwarding the verified `cloneArgs`.
 *
 *      Call chain: Caller → CALL → Clone (EIP-1167 proxy) → DELEGATECALL → Dispatcher → DELEGATECALL → Implementation
 *      - `address(this) == clone` throughout (correct for EIP-712, token balances).
 *      - `msg.sender == original caller` throughout.
 *      - `msg.value == original value` throughout.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDeposit is ICounterfactualDeposit {
    using CounterfactualCloneArgs for CloneArgs;

    /// @notice Canonical `WithdrawImplementation` address referenced by the structural withdraw escape.
    address public immutable WITHDRAW_IMPL;

    constructor(address _withdrawImpl) {
        WITHDRAW_IMPL = _withdrawImpl;
    }

    /// @dev Accept native ETH sent to the clone (user deposits, refunds, LayerZero fees, etc.).
    receive() external payable {}

    /// @inheritdoc ICounterfactualDeposit
    function execute(
        CloneArgs calldata cloneArgs,
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external payable {
        // 1. Verify caller-supplied cloneArgs match the clone's stored hash.
        bytes32 storedHash = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32));
        if (cloneArgs.hash() != storedHash) revert InvalidCloneArgs();

        // 2. Structural withdraw escape — bypasses the policy entirely.
        if (implementation == WITHDRAW_IMPL && msg.sender == cloneArgs.withdrawUser) {
            _delegate(implementation, cloneArgs, params, submitterData);
            return;
        }

        // 3. Standardized destination-identity check on the first two leaf-params fields.
        if (params.length < 64) revert LeafParamsTooShort();
        uint256 leafDestinationChainId;
        bytes32 leafOutputToken;
        assembly {
            leafDestinationChainId := calldataload(params.offset)
            leafOutputToken := calldataload(add(params.offset, 32))
        }
        if (leafDestinationChainId != cloneArgs.destinationChainId || leafOutputToken != cloneArgs.outputToken)
            revert InvalidIdentity();

        // 4. Verify merkle proof against the policy's active root.
        // Double-hashed leaf per the OZ standard, committing to (implementation, paramsHash).
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))));
        bytes32 root = IRoutePolicy(cloneArgs.routePolicyAddress).activeRoot();
        if (!MerkleProof.verify(proof, root, leaf)) revert InvalidProof();

        // 5. Delegatecall the implementation with the verified cloneArgs.
        _delegate(implementation, cloneArgs, params, submitterData);
    }

    function _delegate(
        address implementation,
        CloneArgs calldata cloneArgs,
        bytes calldata params,
        bytes calldata submitterData
    ) private {
        (bool success, bytes memory result) = implementation.delegatecall(
            abi.encodeCall(ICounterfactualImplementation.execute, (cloneArgs, params, submitterData))
        );
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
