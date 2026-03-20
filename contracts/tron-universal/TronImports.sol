// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Entry point for the tron-universal Foundry profile. Importing these contracts here causes
// them (and their dependencies) to be compiled with Tron's solc (bin/solc-tron) and output
// to out-tron-universal/.
import "../sp1-helios/SP1Helios.sol";
import "../sp1-helios/SP1AutoVerifier.sol";
import "../Universal_SpokePool.sol";
