// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IUpgradeRegistry } from "../../interfaces/IUpgradeRegistry.sol";
import { CounterfactualBase } from "./CounterfactualBase.sol";

/**
 * @title CounterfactualBootstrap
 * @notice The permanent, minimal implementation a counterfactual proxy is deployed against, before it
 *         is finalized to the registry's real implementation (`CounterfactualDeposit`).
 * @dev Embeds the `UpgradeRegistry` (via the base) and does only: `initialize(initialRoot)` (writes
 *      `activeRoot`) and the inherited permissionless `syncImplementation()` (its first call is the
 *      "finalize"). It has **no deposit logic**, so a proxy is unusable until finalized. It is never
 *      changed, so it is the stable address anchor: only the bootstrap address (a constant) enters the
 *      proxy's CREATE2 preimage, keeping the real/upgradeable implementation out of the address.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualBootstrap is CounterfactualBase {
    constructor(IUpgradeRegistry registry) CounterfactualBase(registry) {}

    /// @notice Set the proxy's initial route root, and stamp `rootVersion` with the registry's current
    ///         version (a fresh proxy isn't in any published upgrade tree, so it is born "current" and
    ///         can execute immediately; `minRequiredVersion <= version` always holds). Called once, in
    ///         the proxy's init code.
    function initialize(bytes32 initialRoot) external initializer {
        _setActiveRoot(initialRoot);
        _setRootVersion(UPGRADE_REGISTRY.version());
    }
}
