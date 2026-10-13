// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { DeploySP1Helios } from "./DeploySP1Helios.s.sol";

/// @title DeploySP1HeliosFromGenesis
/// @notice Deploys a standalone SP1Helios from an existing genesis.json. Unlike DeploySP1Helios it does not
/// download a released genesis binary (so unreleased or pre-release sp1-helios builds and non-mainnet source
/// chains work), and it deploys neither a Universal SpokePool nor transfers any roles: the deployer keeps
/// DEFAULT_ADMIN_ROLE and whatever updater roles genesis.json grants it.
/// @dev Intended for test deployments, e.g. exercising a new sp1-helios release against Sepolia before it is
/// promoted. Generate genesis.json with the sp1-helios CLI and copy it inside this repo:
///
///   (in sp1-helios) cargo run --bin genesis -- --env-file .env.sepolia --out .
///   cp ../sp1-helios/genesis.json script/universal/genesis.sepolia-mock.json
///
/// A zero `verifier` in genesis.json (what the CLI writes for SP1_PROVER=mock) deploys SP1MockVerifier, which
/// accepts empty proof bytes. Remember MAX_SLOT_AGE: the contract bricks if no update lands within 7 days of its head.
///
/// forge script script/universal/DeploySP1HeliosFromGenesis.s.sol \
///   --sig "run(string)" script/universal/genesis.sepolia-mock.json \
///   --rpc-url <RPC_URL> --broadcast -vvvv
contract DeploySP1HeliosFromGenesis is DeploySP1Helios {
    /// @param genesisPath Path to genesis.json, relative to the project root
    /// @return The address of the deployed SP1Helios contract
    function run(string calldata genesisPath) external returns (address) {
        console.log("=== SP1Helios Deployment (from genesis.json) ===");
        console.log("Genesis file:", genesisPath);

        vm.startBroadcast(vm.deriveKey(vm.envString("MNEMONIC"), 0));
        address helios = deployFromGenesis(readGenesisConfig(genesisPath));
        vm.stopBroadcast();

        return helios;
    }
}
