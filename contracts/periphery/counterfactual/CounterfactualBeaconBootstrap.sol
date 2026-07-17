// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title CounterfactualBeaconBootstrap
 * @notice Minimal, chain-identical UUPS implementation used only to deploy the `CounterfactualBeacon`
 *         proxy at the **same address on every chain**.
 * @dev The real `CounterfactualBeacon` implementation bakes chain-specific immutables in, so its address —
 *      and therefore the proxy's (the implementation is in the proxy init code) — differs per chain. This
 *      bootstrap has no immutables, so it has one deterministic address everywhere; the proxy is created
 *      against it then `upgradeToAndCall`-ed to the chain-specific `CounterfactualBeacon`. After that, set
 *      `implementation`/`upgradeRoot` via the owner setters (the initializer slot is already consumed, so
 *      `CounterfactualBeacon.initialize` can't rerun). Shares the OZ `Ownable2Step`/`UUPS` storage layout,
 *      so the admin set here is preserved.
 *
 *      **Bytecode pinning:** the chain-invariant proxy address depends on this contract's exact creation
 *      code, so any bytecode change (solc/optimizer/imports/AST) moves the Bootstrap and every dependent
 *      address. Once the canonical Bootstrap ships on the first chain, deploy later chains from the saved
 *      canonical creation code, not a recompile — treat it as frozen and flag any PR touching it, its OZ
 *      imports, or its compiler profile.
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
