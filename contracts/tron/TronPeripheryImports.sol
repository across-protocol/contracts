// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Entry point for SpokePoolPeriphery and SwapProxy (and their Tron variants) in the tron Foundry
// profile. These use OZ v4, except the `_safeTransfer` hook: OZ v5 in the mainline contracts (see
// `SafeTransferERC20`), overridden with `TronTransferLib` errors in the Tron variants. Kept in a
// separate file from SP1Helios/Tron_SpokePool (OZ v5) to avoid name collisions.
import "../periphery/SpokePoolPeriphery.sol";
import "../periphery/Tron_SpokePoolPeriphery.sol";
import "../periphery/AcrossEventEmitter.sol";
import "../handlers/TronMulticallHandler.sol";
