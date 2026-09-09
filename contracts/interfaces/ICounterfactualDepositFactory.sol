// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualDepositFactory
 * @notice The deterministic deployer for counterfactual `BeaconProxy` instances. A proxy's address is
 *         `f(salt, initialRoot)`, because the `initialize(initialRoot)` call data sits in the proxy's init
 *         code — so a depositor can be quoted an address before anything is deployed, and the proxy can be
 *         created later (or never, if funds are swept by another route).
 * @dev Implemented by `CounterfactualDepositFactory`. Cross-chain address parity requires the factory and
 *      the beacon to sit at identical addresses on every chain, and the caller to reuse the same `salt`;
 *      `salt = 0` is the canonical choice, giving one address per `initialRoot`. Chain-specific variants
 *      (e.g. `CounterfactualDepositFactoryTron`, for Tron's 0x41 CREATE2 prefix) override prediction only.
 * @custom:security-contact bugs@across.to
 */
interface ICounterfactualDepositFactory {
    /// @notice Emitted when a counterfactual proxy is deployed.
    event CounterfactualDeployed(address indexed counterfactual, bytes32 initialRoot);

    /// @notice The beacon (the `CounterfactualBeacon`) every deployed proxy points at.
    function BEACON() external view returns (address);

    /**
     * @notice Predict the proxy address for a given `salt` and `initialRoot`, deployed or not.
     * @param salt CREATE2 salt; `0` for the canonical address of this `initialRoot`.
     * @param initialRoot The proxy's initial route tree, bound into its address via the init code.
     * @return The counterfactual address.
     */
    function predictAddress(bytes32 salt, bytes32 initialRoot) external view returns (address);

    /**
     * @notice Deploy the proxy for `salt` and `initialRoot`, already initialized and resolving its
     *         implementation live from the beacon. Reverts if it is already deployed.
     * @return counterfactual The deployed proxy address.
     */
    function deploy(bytes32 salt, bytes32 initialRoot) external returns (address counterfactual);

    /**
     * @notice Deploy the proxy, then forward `executeCalldata` to it. Reverts if already deployed.
     * @dev Any `msg.value` is forwarded with the call; a revert in the proxy is bubbled up verbatim.
     * @param executeCalldata Calldata for the proxy (e.g. `abi.encodeCall(ICounterfactualDeposit.execute, …)`).
     * @return counterfactual The deployed proxy address.
     */
    function deployAndExecute(
        bytes32 salt,
        bytes32 initialRoot,
        bytes calldata executeCalldata
    ) external payable returns (address counterfactual);

    /**
     * @notice Deploy the proxy if it does not exist yet, then forward `executeCalldata` to it. Idempotent
     *         in the deployment step, so this is the safe entry point when a proxy may already be live.
     * @param executeCalldata Calldata for the proxy (e.g. `abi.encodeCall(ICounterfactualDeposit.execute, …)`).
     * @return counterfactual The proxy address, newly deployed or pre-existing.
     */
    function deployIfNeededAndExecute(
        bytes32 salt,
        bytes32 initialRoot,
        bytes calldata executeCalldata
    ) external payable returns (address counterfactual);
}
