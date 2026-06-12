// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { CounterfactualDeposit } from "./CounterfactualDeposit.sol";

/**
 * @title CounterfactualDepositFactory
 * @notice Deterministically deploys counterfactual `BeaconProxy` instances. Each proxy uses the global
 *         `CounterfactualBeacon` as its beacon (so it always runs the registry's current implementation) and
 *         is initialized with its route root in the constructor `data`.
 * @dev The `initialize(initialRoot)` call data is part of the proxy's init code, so for a fixed `salt`
 *      the address is `f(salt, initialRoot)`. Callers wanting one canonical address per destination
 *      identity (and automatic cross-chain parity) should pass `salt = 0`; a non-zero `salt` yields
 *      additional addresses for the same `initialRoot` and requires the caller to reuse the same `salt`
 *      on every chain for parity. The factory and the beacon must be deployed deterministically at
 *      identical addresses across chains for cross-chain address parity.
 *      `predictAddress` / `_initCode` / `_computeProxyAddress` are `virtual`/`internal` so chain-specific
 *      variants (e.g. Tron's 0x41 CREATE2 prefix) can override prediction.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositFactory {
    /// @notice The beacon (the `CounterfactualBeacon`) every deployed proxy points at.
    address public immutable BEACON;

    /// @notice Emitted when a counterfactual proxy is deployed.
    event CounterfactualDeployed(address indexed counterfactual, bytes32 initialRoot);

    constructor(address beacon) {
        BEACON = beacon;
    }

    /// @notice Predict the proxy address for a given `salt` and `initialRoot`.
    function predictAddress(bytes32 salt, bytes32 initialRoot) public view virtual returns (address) {
        return _computeProxyAddress(salt, keccak256(_initCode(initialRoot)));
    }

    /// @notice Deploy the proxy for `salt` and `initialRoot` (already initialized + always-current via
    ///         the beacon). Reverts if already deployed.
    function deploy(bytes32 salt, bytes32 initialRoot) public returns (address counterfactual) {
        counterfactual = address(
            new BeaconProxy{ salt: salt }(BEACON, abi.encodeCall(CounterfactualDeposit.initialize, (initialRoot)))
        );
        emit CounterfactualDeployed(counterfactual, initialRoot);
    }

    /// @notice Deploy, then forward `executeCalldata` to the proxy. Reverts if already deployed.
    function deployAndExecute(
        bytes32 salt,
        bytes32 initialRoot,
        bytes calldata executeCalldata
    ) external payable returns (address counterfactual) {
        counterfactual = deploy(salt, initialRoot);
        _execute(counterfactual, executeCalldata);
    }

    /// @notice Deploy if needed (idempotent), then forward `executeCalldata` to the proxy.
    function deployIfNeededAndExecute(
        bytes32 salt,
        bytes32 initialRoot,
        bytes calldata executeCalldata
    ) external payable returns (address counterfactual) {
        counterfactual = predictAddress(salt, initialRoot);
        if (counterfactual.code.length == 0) deploy(salt, initialRoot);
        _execute(counterfactual, executeCalldata);
    }

    /// @dev The proxy creation code (creation bytecode + constructor args) — `virtual` for Tron etc.
    function _initCode(bytes32 initialRoot) internal view virtual returns (bytes memory) {
        return
            abi.encodePacked(
                type(BeaconProxy).creationCode,
                abi.encode(BEACON, abi.encodeCall(CounterfactualDeposit.initialize, (initialRoot)))
            );
    }

    /// @dev CREATE2 address derivation for a `salt` and the proxy init-code hash. `virtual` so
    ///      chain-specific variants (e.g. Tron's 0x41 prefix) can override the derivation. Deployment
    ///      via `deploy()` uses the `create2` opcode directly, which is correct on every chain; this
    ///      hook only governs off-chain-style prediction.
    function _computeProxyAddress(bytes32 salt, bytes32 initCodeHash) internal view virtual returns (address) {
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }

    function _execute(address counterfactual, bytes calldata executeCalldata) private {
        (bool success, bytes memory returnData) = counterfactual.call{ value: msg.value }(executeCalldata);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
