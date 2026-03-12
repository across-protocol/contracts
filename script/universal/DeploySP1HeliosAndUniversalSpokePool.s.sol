// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/// @title DeploySP1HeliosAndUniversalSpokePool
/// @notice Combined Foundry script that orchestrates the full deployment of SP1Helios + Universal_SpokePool.
/// @dev Invokes the individual deployment scripts (DeploySP1Helios.s.sol, DeployUniversalSpokePool.s.sol)
/// via FFI so each gets its own broadcast directory, preserving the expected folder structure for
/// extract-addresses tooling. Role transfers use `cast send` to keep them outside the sub-script broadcasts.
///
/// Deployment flow:
///   1. Deploy SP1Helios light client (via forge script FFI)
///   2. Deploy Universal_SpokePool proxy (via forge script FFI, using SP1Helios address from step 1)
///   3. Transfer SP1Helios VKEY_UPDATER_ROLE and DEFAULT_ADMIN_ROLE from deployer to SpokePool (cast send)
///   4. Verify contracts on Etherscan (optional, via forge script --resume)
///
/// Usage:
///   forge script script/universal/DeploySP1HeliosAndUniversalSpokePool.s.sol \
///     --sig "run(uint256,string,string,bool)" <OFT_FEE_CAP> <RPC_URL> <ETHERSCAN_API_KEY> <BROADCAST> \
///     --ffi
///
/// Example (dry run):
///   forge script script/universal/DeploySP1HeliosAndUniversalSpokePool.s.sol \
///     --sig "run(uint256,string,string,bool)" 78000000000000000000000 "https://rpc.hyperliquid.xyz/evm" "" false --ffi
///
/// Example (broadcast + verify):
///   forge script script/universal/DeploySP1HeliosAndUniversalSpokePool.s.sol \
///     --sig "run(uint256,string,string,bool)" 78000000000000000000000 "https://rpc.hyperliquid.xyz/evm" "YOUR_API_KEY" true --ffi
///
/// Required env vars (loaded from .env, passed through to sub-scripts):
///   MNEMONIC, SP1_RELEASE, SP1_PROVER_MODE, SP1_VERIFIER_ADDRESS,
///   SP1_STATE_UPDATERS, SP1_VKEY_UPDATER, SP1_CONSENSUS_RPCS_LIST
contract DeploySP1HeliosAndUniversalSpokePool is Script {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant VKEY_UPDATER_ROLE = keccak256("VKEY_UPDATER_ROLE");

    function run() external pure {
        revert(
            "Usage: forge script ... --sig 'run(uint256,string,string,bool)' <OFT_FEE_CAP> <RPC_URL> <ETHERSCAN_API_KEY> <BROADCAST> --ffi"
        );
    }

    function run(
        uint256 oftFeeCap,
        string calldata rpcUrl,
        string calldata etherscanApiKey,
        bool doBroadcast
    ) external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);
        string memory pkHex = vm.toString(bytes32(deployerPrivateKey));

        string memory chainId = _ffiText(string.concat("cast chain-id --rpc-url ", rpcUrl));

        console.log("Deployer:", deployer);
        console.log("Chain ID:", chainId);

        // =====================================================================
        // Safety check: abort if a SpokePool already exists on this chain
        // =====================================================================
        string memory deployedAddressesPath = string.concat(vm.projectRoot(), "/broadcast/deployed-addresses.json");
        if (vm.isFile(deployedAddressesPath)) {
            string memory existing = _ffiText(
                string.concat(
                    "jq -r '.chains[\"",
                    chainId,
                    '"].contracts["SpokePool"].address // empty\' ',
                    deployedAddressesPath
                )
            );
            if (bytes(existing).length > 0) {
                console.log("Error: SpokePool already deployed on chain", chainId, "at", existing);
                console.log("This script is intended for fresh deployments only.");
                console.log("Remove the chain entry from", deployedAddressesPath, "if you want to redeploy.");
                revert("SpokePool already exists on target chain");
            }
        }

        // =====================================================================
        // Full build (required for OZ upgrades-core proxy validation)
        // =====================================================================
        console.log("");
        console.log("=== Ensuring full build (required for Universal_SpokePool proxy validation) ===");
        _ffi("forge clean && forge build");

        // =====================================================================
        // Shared flags
        // =====================================================================
        string memory broadcastFlag = doBroadcast ? "--broadcast" : "";
        string memory runDirSuffix = doBroadcast ? "" : "/dry-run";
        string memory verifyArgs = bytes(etherscanApiKey).length > 0
            ? string.concat("--etherscan-api-key ", etherscanApiKey)
            : "";

        // =====================================================================
        // Step 1: Deploy SP1Helios
        // =====================================================================
        console.log("");
        console.log("=== Step 1: Deploying SP1Helios ===");
        _ffi(
            string.concat(
                "forge script script/universal/DeploySP1Helios.s.sol",
                " --rpc-url ",
                rpcUrl,
                " ",
                broadcastFlag,
                " --ffi -vvvv 1>&2"
            )
        );

        // Parse SP1Helios address from broadcast JSON
        string memory heliosRunDir = string.concat(
            vm.projectRoot(),
            "/broadcast/DeploySP1Helios.s.sol/",
            chainId,
            runDirSuffix
        );
        address sp1Helios = vm.parseAddress(
            _ffiText(
                string.concat(
                    "jq -r '.transactions[] | select(.contractName == \"SP1Helios\") | .contractAddress' ",
                    heliosRunDir,
                    "/run-latest.json"
                )
            )
        );
        require(sp1Helios != address(0), "Could not find SP1Helios address in broadcast output");
        console.log("");
        console.log("SP1Helios deployed at:", sp1Helios);

        // =====================================================================
        // Fork block pinning for Step 2
        // Some RPCs return "invalid block height" when Forge forks at "latest"
        // after a recent deployment. Pin to the block where Step 1 confirmed.
        // =====================================================================
        string memory forkBlockArgs = "";
        if (doBroadcast) {
            string memory forkBlockDec = _ffiText(
                string.concat(
                    "val=$(jq -r '.receipts[0].blockNumber // empty' ",
                    heliosRunDir,
                    "/run-latest.json); ",
                    '[ -n "$val" ] && printf \'%d\' "$val"'
                )
            );
            if (bytes(forkBlockDec).length > 0) {
                forkBlockArgs = string.concat("--fork-block-number ", forkBlockDec);
                console.log("Using fork block from Step 1 for simulation:", forkBlockDec);
            }
        }

        // =====================================================================
        // Step 2: Deploy Universal_SpokePool
        // =====================================================================
        console.log("");
        console.log("=== Step 2: Deploying Universal_SpokePool ===");
        _ffi(
            string.concat(
                "forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool",
                " --sig 'run(address,uint256)' ",
                vm.toString(sp1Helios),
                " ",
                vm.toString(oftFeeCap),
                " --rpc-url ",
                rpcUrl,
                " ",
                forkBlockArgs,
                " ",
                broadcastFlag,
                " -vvvv 1>&2"
            )
        );

        // Parse SpokePool proxy address from broadcast JSON (ERC1967Proxy)
        string memory spokeRunDir = string.concat(
            vm.projectRoot(),
            "/broadcast/DeployUniversalSpokePool.s.sol/",
            chainId,
            runDirSuffix
        );
        address spokePool = vm.parseAddress(
            _ffiText(
                string.concat(
                    "jq -r '.transactions[] | select(.contractName == \"ERC1967Proxy\") | .contractAddress' ",
                    spokeRunDir,
                    "/run-latest.json"
                )
            )
        );
        require(spokePool != address(0), "Could not find SpokePool address in broadcast output");
        console.log("");
        console.log("SpokePool deployed at:", spokePool);

        // =====================================================================
        // Step 3: Transfer SP1Helios roles to the SpokePool
        // VKEY_UPDATER_ROLE must be granted before DEFAULT_ADMIN_ROLE is renounced.
        // =====================================================================
        console.log("");
        console.log("=== Step 3: Transferring SP1Helios roles ===");
        console.log("SP1Helios:", sp1Helios);
        console.log("SpokePool:", spokePool);

        string memory vkeyRole = vm.toString(VKEY_UPDATER_ROLE);
        string memory adminRole = vm.toString(DEFAULT_ADMIN_ROLE);

        if (doBroadcast) {
            _castSend(rpcUrl, pkHex, sp1Helios, "grantRole(bytes32,address)", vkeyRole, spokePool);
            _castSend(rpcUrl, pkHex, sp1Helios, "renounceRole(bytes32,address)", vkeyRole, deployer);
            _castSend(rpcUrl, pkHex, sp1Helios, "grantRole(bytes32,address)", adminRole, spokePool);
            _castSend(rpcUrl, pkHex, sp1Helios, "renounceRole(bytes32,address)", adminRole, deployer);

            // Verify role transfers
            console.log("");
            console.log("Verifying role transfers...");

            string memory spokeHasVkey = _castCallText(
                rpcUrl,
                sp1Helios,
                "hasRole(bytes32,address)(bool)",
                vkeyRole,
                spokePool
            );
            string memory deployerHasVkey = _castCallText(
                rpcUrl,
                sp1Helios,
                "hasRole(bytes32,address)(bool)",
                vkeyRole,
                deployer
            );
            string memory spokeHasAdmin = _castCallText(
                rpcUrl,
                sp1Helios,
                "hasRole(bytes32,address)(bool)",
                adminRole,
                spokePool
            );
            string memory deployerHasAdmin = _castCallText(
                rpcUrl,
                sp1Helios,
                "hasRole(bytes32,address)(bool)",
                adminRole,
                deployer
            );

            console.log("SpokePool has VKEY_UPDATER_ROLE:", spokeHasVkey);
            console.log("Deployer has VKEY_UPDATER_ROLE: ", deployerHasVkey);
            console.log("SpokePool has DEFAULT_ADMIN_ROLE:", spokeHasAdmin);
            console.log("Deployer has DEFAULT_ADMIN_ROLE: ", deployerHasAdmin);

            require(
                keccak256(bytes(spokeHasVkey)) == keccak256("true") &&
                    keccak256(bytes(deployerHasVkey)) == keccak256("false") &&
                    keccak256(bytes(spokeHasAdmin)) == keccak256("true") &&
                    keccak256(bytes(deployerHasAdmin)) == keccak256("false"),
                "Role verification failed!"
            );

            console.log("Admin roles transferred successfully.");
        } else {
            console.log("(Skipping admin role transfer in simulation mode -- set BROADCAST=true to execute)");
        }

        // =====================================================================
        // Step 4: Verify contracts on Etherscan
        // Re-runs forge scripts with --resume --verify to submit verification
        // without re-broadcasting. Only runs when both BROADCAST and API key set.
        // =====================================================================
        if (doBroadcast && bytes(verifyArgs).length > 0) {
            console.log("");
            console.log("=== Step 4: Verifying contracts ===");

            _ffi(
                string.concat(
                    "forge script script/universal/DeploySP1Helios.s.sol",
                    " --rpc-url ",
                    rpcUrl,
                    " --verify ",
                    verifyArgs,
                    " --ffi -vvvv --resume",
                    " --private-key ",
                    pkHex,
                    " 1>&2 || echo 'Warning: SP1Helios verification failed (may already be verified)' >&2"
                )
            );

            _ffi(
                string.concat(
                    "forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool",
                    " --sig 'run(address,uint256)' ",
                    vm.toString(sp1Helios),
                    " ",
                    vm.toString(oftFeeCap),
                    " --rpc-url ",
                    rpcUrl,
                    " --verify ",
                    verifyArgs,
                    " -vvvv --resume",
                    " --private-key ",
                    pkHex,
                    " 1>&2 || echo 'Warning: Universal_SpokePool verification failed (may already be verified)' >&2"
                )
            );
        }

        // =====================================================================
        // Summary
        // =====================================================================
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("SP1Helios:", sp1Helios);
        console.log("SpokePool:", spokePool);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Runs a shell command via FFI and returns raw stdout bytes.
    /// WARNING: vm.ffi hex-decodes stdout that looks like valid hex (even without "0x" prefix).
    /// Use `_ffiText` instead when you need the output as a string.
    function _ffi(string memory command) internal returns (bytes memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = command;
        return vm.ffi(cmd);
    }

    /// @dev Runs a shell command via FFI and returns stdout as a string, guaranteed not hex-decoded.
    /// Prefixes output with "S:" so vm.ffi sees non-hex data, then strips the prefix and newline.
    function _ffiText(string memory command) internal returns (string memory) {
        bytes memory raw = _ffi(string.concat("echo -n 'S:'; ", command));
        // Strip the "S:" sentinel prefix (2 bytes) and any trailing newline.
        uint256 start = 2;
        uint256 end = raw.length;
        if (end > start && raw[end - 1] == 0x0a) end--;
        bytes memory result = new bytes(end - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = raw[start + i];
        }
        return string(result);
    }

    /// @dev Sends a transaction via `cast send`.
    function _castSend(
        string memory rpcUrl,
        string memory pkHex,
        address to,
        string memory sig,
        string memory arg1,
        address arg2
    ) internal {
        _ffi(
            string.concat(
                "cast send ",
                vm.toString(to),
                " '",
                sig,
                "'",
                " ",
                arg1,
                " ",
                vm.toString(arg2),
                " --rpc-url ",
                rpcUrl,
                " --private-key ",
                pkHex
            )
        );
    }

    /// @dev Calls a view function via `cast call` and returns the decoded result as a text string.
    function _castCallText(
        string memory rpcUrl,
        address to,
        string memory sig,
        string memory arg1,
        address arg2
    ) internal returns (string memory) {
        return
            _ffiText(
                string.concat(
                    "cast call ",
                    vm.toString(to),
                    " '",
                    sig,
                    "'",
                    " ",
                    arg1,
                    " ",
                    vm.toString(arg2),
                    " --rpc-url ",
                    rpcUrl
                )
            );
    }
}
