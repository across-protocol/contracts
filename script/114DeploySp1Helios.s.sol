// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import { SP1Helios } from "../contracts/sp1-helios/SP1Helios.sol";
import { SP1MockVerifier } from "@sp1-contracts/SP1MockVerifier.sol";
import { ISP1Verifier } from "@sp1-contracts/ISP1Verifier.sol";

/// @title DeployScript
/// @notice Deploy script for the SP1Helios contract.
contract DeployScript is Script {
    function setUp() public {}

    function run() public returns (address) {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        vm.startBroadcast(deployerPrivateKey);

        // Update the rollup config to match the current chain. If the starting block number is 0, the latest block number and starting output root will be fetched.
        updateGenesisConfig();

        SP1Helios.InitParams memory params = readGenesisConfig();

        // If the verifier address is set to 0, set it to the address of the mock verifier.
        if (params.verifier == address(0)) {
            params.verifier = address(new SP1MockVerifier());
        }

        // Deploy the SP1 Helios contract.
        SP1Helios helios = new SP1Helios(params);

        vm.stopBroadcast();

        return address(helios);
    }

    function readGenesisConfig() public view returns (SP1Helios.InitParams memory params) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/", "genesis.json");
        string memory json = vm.readFile(path);

        // Manually parse each field from the JSON. Required because of `updaters` memory allocations
        params.executionStateRoot = vm.parseJsonBytes32(json, ".executionStateRoot");
        params.genesisTime = vm.parseJsonUint(json, ".genesisTime");
        params.head = vm.parseJsonUint(json, ".head");
        params.header = vm.parseJsonBytes32(json, ".header");
        params.heliosProgramVkey = vm.parseJsonBytes32(json, ".heliosProgramVkey");
        params.secondsPerSlot = vm.parseJsonUint(json, ".secondsPerSlot");
        params.slotsPerEpoch = vm.parseJsonUint(json, ".slotsPerEpoch");
        params.slotsPerPeriod = vm.parseJsonUint(json, ".slotsPerPeriod");
        params.syncCommitteeHash = vm.parseJsonBytes32(json, ".syncCommitteeHash");
        params.verifier = vm.parseJsonAddress(json, ".verifier");
        params.updaters = vm.parseJsonAddressArray(json, ".updaters");
    }

    function updateGenesisConfig() public {
        // If ENV_FILE is set, pass it to the genesis binary.
        string memory envFile = vm.envOr("ENV_FILE", string(".env"));

        // Build the genesis binary. Use the quiet flag to suppress build output.
        string[] memory inputs = new string[](6);
        inputs[0] = "cargo";
        inputs[1] = "build";
        inputs[2] = "--bin";
        inputs[3] = "genesis";
        inputs[4] = "--release";
        inputs[5] = "--quiet";
        vm.ffi(inputs);

        // Run the genesis binary which updates the genesis config.
        // Use the quiet flag to suppress build output.
        string[] memory inputs2 = new string[](9);
        inputs2[0] = "cargo";
        inputs2[1] = "run";
        inputs2[2] = "--bin";
        inputs2[3] = "genesis";
        inputs2[4] = "--release";
        inputs2[5] = "--quiet";
        inputs2[6] = "--";
        inputs2[7] = "--env-file";
        inputs2[8] = envFile;

        vm.ffi(inputs2);
    }
}
