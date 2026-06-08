// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title CounterfactualBeaconBootstrap
 * @notice Minimal, chain-identical UUPS implementation used only to deploy the `CounterfactualBeacon`
 *         proxy at the **same address on every chain**.
 * @dev The real `CounterfactualBeacon` implementation bakes chain-specific values in as immutables, so its
 *      address differs per chain — pointing the proxy straight at it would make the proxy address differ
 *      per chain too (the implementation is part of the proxy's init code). This bootstrap has no
 *      immutables, so it deploys to one deterministic address everywhere; the proxy is created against it
 *      (identical init code ⇒ identical proxy address), then `upgradeToAndCall`-ed to the chain-specific
 *      `CounterfactualBeacon`. After the upgrade, set `implementation`/`upgradeRoot` via the owner setters
 *      (the `initializer` slot is already consumed here, so `CounterfactualBeacon.initialize` cannot run
 *      again). Shares the OZ `Ownable2Step`/`UUPS` storage layout, so the admin set here is preserved.
 *
 *      **Bytecode pinning (deploy-time concern).** The chain-invariant proxy address depends on this
 *      Bootstrap's CREATE2 address, which depends on this contract's exact compiled creation code. Any
 *      change that alters the bytecode — solc version bump, optimizer settings, import path resolution,
 *      even a no-op source edit that changes the AST — moves the Bootstrap (and with it the beacon
 *      proxy, the dispatcher, and every counterfactual proxy) to a different address. Once the
 *      canonical Bootstrap lands on the first chain, every later chain MUST be deployed from the
 *      **saved canonical creation code** (e.g. a committed bytecode artifact), NOT a recompile of this
 *      source. Treat this contract as effectively frozen the moment its first canonical deployment
 *      ships; surface any future PR that touches it (or its OZ imports, or the compiler profile it's
 *      built under) so the bytecode-pinning workflow is followed.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualBeaconBootstrap is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    constructor() {
        _disableInitializers();
    }

    /// @notice Set the admin that will perform the upgrade to the chain-specific implementation.
    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
