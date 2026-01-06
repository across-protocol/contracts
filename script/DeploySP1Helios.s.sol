// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { SP1Helios } from "../contracts/sp1-helios/SP1Helios.sol";
import { SP1MockVerifier } from "@sp1-contracts/SP1MockVerifier.sol";

/// @title DeploySP1Helios
/// @notice Deploy script for the SP1Helios contract.
/// @dev This script downloads the genesis binary from the SP1Helios GitHub releases,
///      runs it to generate the genesis.json, then deploys the SP1Helios contract.
///
/// How to run:
/// 1. Set environment variables in .env:
///    - MNEMONIC or PRIVATE_KEY for deployment
///    - CONSENSUS_RPC_URL - Ethereum consensus layer RPC
///    - SP1_VERIFIER_ADDRESS - SP1 verifier contract address
///    - SP1_UPDATERS - Comma-separated list of updater addresses
///    - SP1_VKEY_UPDATER - VKey updater address
///
/// 2. Run the script:
///    forge script script/DeploySP1Helios.s.sol \
///      --sig "run(string,string)" "0.1.0-alpha.17" "mock" \
///      --rpc-url <RPC_URL> --broadcast --ffi -vvvv
///
///    Arguments:
///      - version: Genesis binary version (e.g., "0.1.0-alpha.17")
///      - sp1Prover: SP1 prover type - "mock", "cpu", "cuda", or "network"
///
/// Binary naming convention:
///    - macOS (arm64): genesis_{version}_arm64_darwin
///    - Linux (amd64): genesis_{version}_amd64_linux
contract DeploySP1Helios is Script {
    // GitHub release URL pattern for the genesis binary
    string internal constant GITHUB_RELEASE_URL = "https://github.com/across-protocol/sp1-helios/releases";

    /// @notice Main entry point for deploying SP1Helios
    /// @param version Genesis binary version (e.g., "0.1.0-alpha.17")
    /// @param sp1Prover SP1 prover type: "mock", "cpu", "cuda", or "network"
    /// @return The address of the deployed SP1Helios contract
    function run(string calldata version, string calldata sp1Prover) external returns (address) {
        console.log("=== SP1Helios Deployment ===");
        console.log("Version:", version);
        console.log("SP1 Prover:", sp1Prover);

        // Get deployer private key
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 pk) {
            deployerPrivateKey = pk;
        } catch {
            string memory mnemonic = vm.envString("MNEMONIC");
            deployerPrivateKey = vm.deriveKey(mnemonic, 0);
        }

        vm.startBroadcast(deployerPrivateKey);

        // Download and run the genesis binary to create/update genesis.json
        downloadAndRunGenesisBinary(version, sp1Prover);

        // Read the genesis config from genesis.json
        SP1Helios.InitParams memory params = readGenesisConfig();

        // If the verifier address is set to 0, deploy a mock verifier
        if (params.verifier == address(0)) {
            console.log("Deploying SP1MockVerifier (verifier was address(0))...");
            params.verifier = address(new SP1MockVerifier());
            console.log("SP1MockVerifier deployed to:", params.verifier);
        }

        // Deploy the SP1 Helios contract
        console.log("Deploying SP1Helios...");
        SP1Helios helios = new SP1Helios(params);
        console.log("SP1Helios deployed to:", address(helios));

        // Log configuration
        console.log("Genesis Time:", params.genesisTime);
        console.log("Head:", params.head);
        console.log("Seconds Per Slot:", params.secondsPerSlot);
        console.log("Slots Per Epoch:", params.slotsPerEpoch);
        console.log("Slots Per Period:", params.slotsPerPeriod);
        console.log("Verifier:", params.verifier);
        console.log("VKey Updater:", params.vkeyUpdater);
        console.log("Number of Updaters:", params.updaters.length);
        for (uint256 i = 0; i < params.updaters.length; i++) {
            console.log("  Updater", i, ":", params.updaters[i]);
        }

        vm.stopBroadcast();

        return address(helios);
    }

    /// @notice Reads the genesis configuration from genesis.json
    function readGenesisConfig() public view returns (SP1Helios.InitParams memory params) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/contracts/genesis.json");
        string memory json = vm.readFile(path);

        // Parse each field from the JSON
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
        params.vkeyUpdater = vm.parseJsonAddress(json, ".vkeyUpdater");
        params.updaters = vm.parseJsonAddressArray(json, ".updaters");
    }

    /// @notice Downloads the genesis binary from GitHub releases and runs it
    /// @param version Genesis binary version
    /// @param sp1Prover SP1 prover type
    function downloadAndRunGenesisBinary(string calldata version, string calldata sp1Prover) internal {
        string memory envFile = vm.envOr("ENV_FILE", string(".env"));
        console.log("Env file:", envFile);

        // Derive private key from mnemonic to pass to genesis binary
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 privateKey = vm.deriveKey(mnemonic, 0);
        string memory privateKeyHex = vm.toString(bytes32(privateKey));

        // Read additional env vars to pass to genesis binary
        string memory sp1VerifierAddress = vm.envString("SP1_VERIFIER_ADDRESS");
        string memory updaters = vm.envString("SP1_UPDATERS");
        string memory vkeyUpdater = vm.envString("SP1_VKEY_UPDATER");
        console.log("SP1_VERIFIER_ADDRESS:", sp1VerifierAddress);
        console.log("UPDATERS:", updaters);
        console.log("VKEY_UPDATER:", vkeyUpdater);

        // Detect OS/arch and construct binary name
        // Format: genesis_{version}_{arch}_{os}
        // macOS: genesis_{version}_arm64_darwin
        // Linux: genesis_{version}_amd64_linux
        string memory platformSuffix = detectPlatform();
        string memory binaryName = string.concat("genesis_", version, "_", platformSuffix);
        console.log("Binary name:", binaryName);

        // Construct download URL
        // Format: https://github.com/across-protocol/sp1-helios/releases/download/v{version}/{binaryName}
        string memory downloadUrl = string.concat(GITHUB_RELEASE_URL, "/download/v", version, "/", binaryName);
        console.log("Download URL:", downloadUrl);

        // Download to project root
        string memory binaryPath = string.concat(vm.projectRoot(), "/genesis-binary");

        console.log("Downloading genesis binary...");
        string[] memory downloadCmd = new string[](6);
        downloadCmd[0] = "curl";
        downloadCmd[1] = "-L";
        downloadCmd[2] = "-o";
        downloadCmd[3] = binaryPath;
        downloadCmd[4] = "--fail";
        downloadCmd[5] = downloadUrl;
        vm.ffi(downloadCmd);
        console.log("Download complete");

        // Make executable
        string[] memory chmodCmd = new string[](3);
        chmodCmd[0] = "chmod";
        chmodCmd[1] = "+x";
        chmodCmd[2] = binaryPath;
        vm.ffi(chmodCmd);

        console.log("Running genesis binary...");

        // Read additional env vars needed by genesis binary
        string memory consensusRpcUrl = vm.envString("CONSENSUS_RPC_URL");

        // Run the genesis binary with all required env vars passed directly
        // (not using --env-file to avoid potential override issues)
        string[] memory runCmd = new string[](9);
        runCmd[0] = "env";
        runCmd[1] = "SOURCE_CHAIN_ID=1";
        runCmd[2] = string.concat("SP1_PROVER=", sp1Prover);
        runCmd[3] = string.concat("PRIVATE_KEY=", privateKeyHex);
        runCmd[4] = string.concat("SP1_VERIFIER_ADDRESS=", sp1VerifierAddress);
        runCmd[5] = string.concat("UPDATERS=", updaters);
        runCmd[6] = string.concat("VKEY_UPDATER=", vkeyUpdater);
        runCmd[7] = string.concat("CONSENSUS_RPC_URL=", consensusRpcUrl);
        runCmd[8] = binaryPath;
        vm.ffi(runCmd);

        console.log("Genesis config updated successfully");
    }

    /// @notice Detects the operating system and returns the platform suffix for the binary name
    /// @return Platform suffix: "arm64_darwin" for macOS, "amd64_linux" for Linux
    function detectPlatform() internal returns (string memory) {
        string[] memory unameCmd = new string[](2);
        unameCmd[0] = "uname";
        unameCmd[1] = "-s";
        bytes memory result = vm.ffi(unameCmd);

        // Trim newline from uname output
        if (result.length > 0 && result[result.length - 1] == 0x0a) {
            assembly {
                mstore(result, sub(mload(result), 1))
            }
        }

        if (keccak256(result) == keccak256(bytes("Darwin"))) {
            console.log("Detected platform: macOS (arm64_darwin)");
            return "arm64_darwin";
        } else {
            console.log("Detected platform: Linux (amd64_linux)");
            return "amd64_linux";
        }
    }
}
