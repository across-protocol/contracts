// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Entry point for SP1Helios and UniversalSpokePool in the tron Foundry profile. These use OZ v5
// and must be in a separate file from counterfactual contracts (OZ v4) to avoid name collisions.
import "../sp1-helios/SP1Helios.sol";
import "../sp1-helios/SP1AutoVerifier.sol";
import "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import "../spoke-pools/Universal_SpokePool.sol";
