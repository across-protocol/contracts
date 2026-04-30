// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Entry point for SpokePoolPeriphery and SwapProxy in the tron Foundry profile. These use OZ v4
// and are kept in a separate file from SP1Helios/UniversalSpokePool (OZ v5) to avoid name collisions.
import "../periphery/SpokePoolPeriphery.sol";
