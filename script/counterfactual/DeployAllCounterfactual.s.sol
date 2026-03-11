// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

// Deploys all 7 counterfactual contracts by invoking each individual deploy script via ffi.
// Each `forge script` invocation is separate, so broadcast artifacts are recorded in each
// deploy script's own folder (e.g. broadcast/DeployCounterfactualDeposit/<chainId>/).
//
// CREATE addresses are determined by (sender, nonce). By deploying from the same address
// starting at nonce 0 on every chain, each contract lands at the same address across all
// chains regardless of constructor arguments.
//
// Deployment order (nonce -> contract):
//   0 = CounterfactualDeposit
//   1 = CounterfactualDepositFactory
//   2 = WithdrawImplementation
//   3 = CounterfactualDepositSpokePool
//   4 = CounterfactualDepositCCTP
//   5 = CounterfactualDepositOFT
//   6 = AdminWithdrawManager
//
// Environment variables:
//   MNEMONIC          - Required. Mnemonic phrase for key derivation.
//   DEPLOYER_INDEX    - Optional. BIP-44 derivation index (m/44'/60'/0'/0/<index>). Defaults to 0.
//   SKIP              - Optional. Comma-separated deployment indices to skip (e.g. "4,5").
//                       Skipped deployments burn the nonce with a 0-value self-transfer
//                       so subsequent contracts still get the correct addresses.
//
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. DEPLOYER_INDEX=5 forge script \
//      script/counterfactual/DeployAllCounterfactual.s.sol:DeployAllCounterfactual \
//      --sig "run(string,address,address,address,address,uint32,address,uint32,address,address,bool)" \
//      $NODE_URL <spokePool> <signer> <wrappedNativeToken> \
//      <cctpPeriphery> <cctpDomain> <oftPeriphery> <oftEid> \
//      <owner> <directWithdrawer> true \
//      --rpc-url $NODE_URL -vvvv
// 3. Verify the logged forge commands look correct
// 4. Deploy: set the last arg (broadcast) to true and add --ffi to the command
//
// To skip deployments (e.g. CCTP and OFT):
//   DEPLOYER_INDEX=5 SKIP=4,5 forge script ... --ffi
contract DeployAllCounterfactual is Script, Test {
    // Total number of counterfactual contracts to deploy.
    uint256 constant TOTAL_DEPLOYMENTS = 7;

    // Individual deploy script paths, relative to the repo root.
    string constant SCRIPT_DIR = "script/counterfactual/";

    function run(
        string calldata rpcUrl,
        address spokePool,
        address signer,
        address wrappedNativeToken,
        address cctpPeriphery,
        uint32 cctpDomain,
        address oftPeriphery,
        uint32 oftEid,
        address owner,
        address directWithdrawer,
        bool broadcast
    ) external {
        // Derive the deployer's address from the mnemonic to check its nonce.
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 deployerIndex = vm.envOr("DEPLOYER_INDEX", uint256(0));
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, uint32(deployerIndex));
        address deployer = vm.addr(deployerPrivateKey);

        // Parse the SKIP env var into a boolean array. Each index (0-6) maps to a contract.
        bool[TOTAL_DEPLOYMENTS] memory skip = _parseSkipList();

        // Log the deployer's current nonce on-chain.
        uint64 nonce = vm.getNonce(deployer);

        console.log("============================================");
        console.log("Counterfactual Contracts Deployment");
        console.log("============================================");
        console.log("Deployer: ", deployer);
        console.log("Nonce:    ", uint256(nonce));
        console.log("Chain ID: ", block.chainid);
        console.log("Broadcast:", broadcast);
        console.log("============================================");

        // Build the common forge flags used for every deploy script invocation.
        string memory broadcastFlag = broadcast ? " --broadcast --verify --retries 5 --delay 10" : "";

        // --- Nonce 0: CounterfactualDeposit ---
        // Base implementation that all clones proxy to.
        if (skip[0]) {
            _burnNonce(deployer, deployerPrivateKey, rpcUrl, 0, "CounterfactualDeposit", broadcast);
        } else {
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDeposit.s.sol"),
                "DeployCounterfactualDeposit",
                "", // no --sig needed, uses default run()
                0,
                "CounterfactualDeposit"
            );
        }

        // --- Nonce 1: CounterfactualDepositFactory ---
        // Factory that deploys deterministic clones via CREATE2.
        if (skip[1]) {
            _burnNonce(deployer, deployerPrivateKey, rpcUrl, 1, "CounterfactualDepositFactory", broadcast);
        } else {
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositFactory.s.sol"),
                "DeployCounterfactualDepositFactory",
                "",
                1,
                "CounterfactualDepositFactory"
            );
        }

        // --- Nonce 2: WithdrawImplementation ---
        // Withdraw implementation, included as a merkle leaf in each clone.
        if (skip[2]) {
            _burnNonce(deployer, deployerPrivateKey, rpcUrl, 2, "WithdrawImplementation", broadcast);
        } else {
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployWithdrawImplementation.s.sol"),
                "DeployWithdrawImplementation",
                "",
                2,
                "WithdrawImplementation"
            );
        }

        // --- Nonce 3: CounterfactualDepositSpokePool ---
        // Deposit implementation for Across SpokePool bridge type.
        if (skip[3]) {
            _burnNonce(deployer, deployerPrivateKey, rpcUrl, 3, "CounterfactualDepositSpokePool", broadcast);
        } else {
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositSpokePool.s.sol"),
                "DeployCounterfactualDepositSpokePool",
                string.concat(
                    ' --sig "run(address,address,address)" ',
                    vm.toString(spokePool),
                    " ",
                    vm.toString(signer),
                    " ",
                    vm.toString(wrappedNativeToken)
                ),
                3,
                "CounterfactualDepositSpokePool"
            );
        }

        // --- Nonce 4: CounterfactualDepositCCTP ---
        // Deposit implementation for Circle CCTP bridge type.
        if (skip[4]) {
            _burnNonce(deployer, deployerPrivateKey, rpcUrl, 4, "CounterfactualDepositCCTP", broadcast);
        } else {
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositCCTP.s.sol"),
                "DeployCounterfactualDepositCCTP",
                string.concat(
                    ' --sig "run(address,uint32)" ',
                    vm.toString(cctpPeriphery),
                    " ",
                    vm.toString(uint256(cctpDomain))
                ),
                4,
                "CounterfactualDepositCCTP"
            );
        }

        // --- Nonce 5: CounterfactualDepositOFT ---
        // Deposit implementation for LayerZero OFT bridge type.
        if (skip[5]) {
            _burnNonce(deployer, deployerPrivateKey, rpcUrl, 5, "CounterfactualDepositOFT", broadcast);
        } else {
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositOFT.s.sol"),
                "DeployCounterfactualDepositOFT",
                string.concat(
                    ' --sig "run(address,uint32)" ',
                    vm.toString(oftPeriphery),
                    " ",
                    vm.toString(uint256(oftEid))
                ),
                5,
                "CounterfactualDepositOFT"
            );
        }

        // --- Nonce 6: AdminWithdrawManager ---
        // Admin contract for managing withdrawals from clones.
        if (skip[6]) {
            _burnNonce(deployer, deployerPrivateKey, rpcUrl, 6, "AdminWithdrawManager", broadcast);
        } else {
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployAdminWithdrawManager.s.sol"),
                "DeployAdminWithdrawManager",
                string.concat(
                    ' --sig "run(address,address,address)" ',
                    vm.toString(owner),
                    " ",
                    vm.toString(directWithdrawer),
                    " ",
                    vm.toString(signer)
                ),
                6,
                "AdminWithdrawManager"
            );
        }

        console.log("============================================");
        console.log("All deployments complete!");
        console.log("============================================");
    }

    /// @dev Invokes a single deploy script via `forge script` using vm.ffi().
    /// Each invocation is a separate forge process, so broadcast artifacts are written
    /// to the individual script's broadcast folder.
    function _runForgeScript(
        string memory rpcUrl,
        string memory broadcastFlag,
        string memory scriptPath,
        string memory contractName,
        string memory sigArgs,
        uint256 index,
        string memory description
    ) internal {
        console.log("[%d] Deploying %s...", index, description);

        // Build the full forge command. The DEPLOYER_INDEX env var is inherited by the
        // child process since it was set in the parent's environment.
        // Append `|| true` so that non-fatal failures (e.g. etherscan verification
        // timing out) don't cause ffi to revert and halt subsequent deployments.
        string memory cmd = string.concat(
            "forge script ",
            scriptPath,
            ":",
            contractName,
            sigArgs,
            " --rpc-url ",
            rpcUrl,
            broadcastFlag,
            " -vvvv || true"
        );

        console.log("  cmd: %s", cmd);

        // Execute via bash so that the full command string is parsed correctly
        // (handles --sig with quotes, multiple args, etc).
        string[] memory args = new string[](3);
        args[0] = "bash";
        args[1] = "-c";
        args[2] = cmd;
        vm.ffi(args);

        console.log("[%d] %s deployed.", index, description);
    }

    /// @dev Burns a nonce by sending a 0-value self-transfer via `cast send`.
    /// Uses ffi when broadcasting, otherwise logs a skip message.
    function _burnNonce(
        address deployer,
        uint256 deployerPrivateKey,
        string memory rpcUrl,
        uint256 index,
        string memory name,
        bool broadcast
    ) internal {
        console.log("[%d] %s: SKIPPED (burning nonce)", index, name);

        if (broadcast) {
            // Use cast send to burn the nonce with a 0-value self-transfer.
            string[] memory args = new string[](3);
            args[0] = "bash";
            args[1] = "-c";
            args[2] = string.concat(
                "cast send ",
                vm.toString(deployer),
                " --value 0 --private-key ",
                vm.toString(bytes32(deployerPrivateKey)),
                " --rpc-url ",
                rpcUrl
            );
            vm.ffi(args);
        }
    }

    /// @dev Parses the SKIP env var (comma-separated indices like "4,5") into a boolean array.
    /// Returns a fixed-size array where skip[i] == true means deployment i should be skipped.
    function _parseSkipList() internal view returns (bool[TOTAL_DEPLOYMENTS] memory skip) {
        // If SKIP is not set, return all false (deploy everything).
        string memory skipEnv = vm.envOr("SKIP", string(""));
        if (bytes(skipEnv).length == 0) return skip;

        // Parse comma-separated indices. Each character is either a digit (0-6) or a comma.
        bytes memory raw = bytes(skipEnv);
        for (uint256 i = 0; i < raw.length; i++) {
            if (raw[i] == ",") continue;
            uint8 digit = uint8(raw[i]) - 48; // ASCII '0' = 48
            require(digit < TOTAL_DEPLOYMENTS, "Invalid skip index");
            skip[digit] = true;
        }
    }
}
