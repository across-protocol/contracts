// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CounterfactualBootstrap } from "./CounterfactualBootstrap.sol";

/**
 * @title CounterfactualDepositFactory
 * @notice Deterministically deploys upgradeable counterfactual proxies. Each proxy is created against a
 *         fixed `BOOTSTRAP` implementation with the route root in its init code, then immediately
 *         finalized (synced to the registry's `currentImplementation`).
 * @dev The CREATE2 salt is fixed to `0`, so the address is purely `f(initialRoot)` — one destination
 *      identity ⇒ one address. Only the bootstrap (a constant) enters the preimage, so the real
 *      implementation never affects the address. The factory itself must be deployed deterministically
 *      at the same address on every chain for cross-chain address parity. `predictAddress` and the
 *      proxy init code are `virtual`/`internal` so chain-specific variants (e.g. Tron's 0x41 CREATE2
 *      prefix) can override prediction.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositFactory {
    /// @notice The permanent bootstrap implementation every proxy is deployed against.
    address public immutable BOOTSTRAP;

    /// @notice Emitted when a counterfactual proxy is deployed (and finalized).
    event CounterfactualDeployed(address indexed counterfactual, bytes32 initialRoot);

    constructor(address bootstrap) {
        BOOTSTRAP = bootstrap;
    }

    /// @notice Predict the proxy address for a given `initialRoot` (salt is fixed to 0).
    function predictAddress(bytes32 initialRoot) public view virtual returns (address) {
        return _computeProxyAddress(keccak256(_initCode(initialRoot)));
    }

    /// @notice Deploy and finalize the proxy for `initialRoot`. Reverts if already deployed.
    function deploy(bytes32 initialRoot) public returns (address counterfactual) {
        counterfactual = address(
            new ERC1967Proxy{ salt: bytes32(0) }(
                BOOTSTRAP,
                abi.encodeCall(CounterfactualBootstrap.initialize, (initialRoot))
            )
        );
        // Finalize: upgrade off the (deposit-less) bootstrap to the registry's current implementation.
        CounterfactualBootstrap(payable(counterfactual)).syncImplementation();
        emit CounterfactualDeployed(counterfactual, initialRoot);
    }

    /// @notice Deploy + finalize, then forward `executeCalldata` to the proxy. Reverts if already deployed.
    function deployAndExecute(
        bytes32 initialRoot,
        bytes calldata executeCalldata
    ) external payable returns (address counterfactual) {
        counterfactual = deploy(initialRoot);
        _execute(counterfactual, executeCalldata);
    }

    /// @notice Deploy + finalize if needed (idempotent), then forward `executeCalldata` to the proxy.
    function deployIfNeededAndExecute(
        bytes32 initialRoot,
        bytes calldata executeCalldata
    ) external payable returns (address counterfactual) {
        counterfactual = predictAddress(initialRoot);
        if (counterfactual.code.length == 0) deploy(initialRoot);
        _execute(counterfactual, executeCalldata);
    }

    /// @dev The proxy creation code (creation bytecode + constructor args) — `virtual` for Tron etc.
    function _initCode(bytes32 initialRoot) internal view virtual returns (bytes memory) {
        return
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(BOOTSTRAP, abi.encodeCall(CounterfactualBootstrap.initialize, (initialRoot)))
            );
    }

    /// @dev CREATE2 address derivation for the proxy init-code hash (salt fixed to 0). `virtual` so
    ///      chain-specific variants (e.g. Tron's 0x41 prefix) can override the derivation. Deployment
    ///      via `deploy()` uses the `create2` opcode directly, which is correct on every chain; this
    ///      hook only governs off-chain-style prediction.
    function _computeProxyAddress(bytes32 initCodeHash) internal view virtual returns (address) {
        return Create2.computeAddress(bytes32(0), initCodeHash, address(this));
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
