// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { StdConstants } from "forge-std/StdConstants.sol";

import { CounterfactualDeposit } from "../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { WithdrawImplementation } from "../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { CounterfactualDepositOFT } from "../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// Deploys all 7 counterfactual contracts via CREATE2 using the deterministic deployment proxy
// (0x4e59b44847b379578588920cA78FbF26c0B4956C). Each individual deploy script is invoked via ffi
// so broadcast artifacts are recorded in each script's own folder.
//
// CREATE2 addresses are determined by (factory, salt, initCode). Contracts with identical initCode
// across chains (no constructor args, or same constructor args) get the same address everywhere.
// Contracts with chain-specific constructor args get chain-specific addresses.
//
// Same address across all chains:
//   - CounterfactualDeposit (no constructor args)
//   - CounterfactualDepositFactory (no constructor args)
//   - WithdrawImplementation (no constructor args)
//   - AdminWithdrawManager (same constructor args on all chains)
//
// Chain-specific addresses (different constructor args per chain):
//   - CounterfactualDepositSpokePool
//   - CounterfactualDepositCCTP
//   - CounterfactualDepositOFT
//
// Advantages over nonce-based (CREATE) deployment:
//   - No fresh EOA required — any funded address can deploy
//   - No nonce burning for skipped contracts
//   - No ordering dependency — deploy in any order
//   - Idempotent — already-deployed contracts are auto-skipped
//
// Deployment index -> contract (for SKIP env var):
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
//   SKIP              - Optional. Comma-separated deployment indices to skip (e.g. "4,5").
//
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script \
//      script/counterfactual/DeployAllCounterfactualCreate2.s.sol:DeployAllCounterfactualCreate2 \
//      --sig "run(string,address,address,address,address,uint32,address,uint32,address,address,bool)" \
//      <rpcUrl> <spokePool> <signer> <wrappedNativeToken> \
//      <cctpPeriphery> <cctpDomain> <oftPeriphery> <oftEid> \
//      <owner> <directWithdrawer> true \
//      --rpc-url <rpcUrl> --ffi -vvvv
// 3. Verify the logged predicted addresses and forge commands look correct
//
// To skip deployments (e.g. CCTP and OFT):
//   SKIP=4,5 forge script ... --ffi
contract DeployAllCounterfactualCreate2 is Script, Test {
    uint256 constant TOTAL_DEPLOYMENTS = 7;

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
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        bool[TOTAL_DEPLOYMENTS] memory skip = _parseSkipList();

        // Log predicted addresses upfront so they can be verified before deploying.
        console.log("============================================");
        console.log("Counterfactual Contracts CREATE2 Deployment");
        console.log("============================================");
        console.log("Deployer:  ", deployer);
        console.log("Chain ID:  ", block.chainid);
        console.log("Broadcast: ", broadcast);
        console.log("--------------------------------------------");
        console.log("Predicted addresses:");

        address[TOTAL_DEPLOYMENTS] memory predicted;
        predicted[0] = _predictCreate2(bytes32(0), type(CounterfactualDeposit).creationCode);
        predicted[1] = _predictCreate2(bytes32(0), type(CounterfactualDepositFactory).creationCode);
        predicted[2] = _predictCreate2(bytes32(0), type(WithdrawImplementation).creationCode);
        predicted[3] = _predictCreate2(
            bytes32(0),
            abi.encodePacked(
                type(CounterfactualDepositSpokePool).creationCode,
                abi.encode(spokePool, signer, wrappedNativeToken)
            )
        );
        predicted[4] = _predictCreate2(
            bytes32(0),
            abi.encodePacked(type(CounterfactualDepositCCTP).creationCode, abi.encode(cctpPeriphery, cctpDomain))
        );
        predicted[5] = _predictCreate2(
            bytes32(0),
            abi.encodePacked(type(CounterfactualDepositOFT).creationCode, abi.encode(oftPeriphery, oftEid))
        );
        predicted[6] = _predictCreate2(
            bytes32(0),
            abi.encodePacked(type(AdminWithdrawManager).creationCode, abi.encode(owner, directWithdrawer, signer))
        );

        string[TOTAL_DEPLOYMENTS] memory names = [
            "CounterfactualDeposit",
            "CounterfactualDepositFactory",
            "WithdrawImplementation",
            "CounterfactualDepositSpokePool",
            "CounterfactualDepositCCTP",
            "CounterfactualDepositOFT",
            "AdminWithdrawManager"
        ];

        // Auto-skip contracts that are already deployed at the predicted address.
        for (uint256 i = 0; i < TOTAL_DEPLOYMENTS; i++) {
            if (predicted[i].code.length > 0) skip[i] = true;
            string memory status = skip[i] ? " [SKIP]" : "";
            if (predicted[i].code.length > 0) status = " [ALREADY DEPLOYED]";
            console.log("  [%d] %s: %s", i, string.concat(names[i], status), predicted[i]);
        }
        console.log("============================================");

        string memory broadcastFlag = broadcast ? " --broadcast --verify --retries 5 --delay 10" : "";

        // --- 0: CounterfactualDeposit (base implementation that all clones proxy to) ---
        if (skip[0]) {
            console.log("[0] CounterfactualDeposit: SKIPPED");
        } else {
            console.log("[0] Deploying CounterfactualDeposit...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositCreate2.s.sol"),
                "DeployCounterfactualDepositCreate2",
                "",
                0
            );
        }

        // --- 1: CounterfactualDepositFactory (factory that deploys deterministic clones via CREATE2) ---
        if (skip[1]) {
            console.log("[1] CounterfactualDepositFactory: SKIPPED");
        } else {
            console.log("[1] Deploying CounterfactualDepositFactory...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositFactoryCreate2.s.sol"),
                "DeployCounterfactualDepositFactoryCreate2",
                "",
                1
            );
        }

        // --- 2: WithdrawImplementation (withdraw logic, included as a merkle leaf in each clone) ---
        if (skip[2]) {
            console.log("[2] WithdrawImplementation: SKIPPED");
        } else {
            console.log("[2] Deploying WithdrawImplementation...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployWithdrawImplementationCreate2.s.sol"),
                "DeployWithdrawImplementationCreate2",
                "",
                2
            );
        }

        // --- 3: CounterfactualDepositSpokePool (deposit implementation for Across SpokePool) ---
        if (skip[3]) {
            console.log("[3] CounterfactualDepositSpokePool: SKIPPED");
        } else {
            console.log("[3] Deploying CounterfactualDepositSpokePool...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositSpokePoolCreate2.s.sol"),
                "DeployCounterfactualDepositSpokePoolCreate2",
                string.concat(
                    ' --sig "run(address,address,address)" ',
                    vm.toString(spokePool),
                    " ",
                    vm.toString(signer),
                    " ",
                    vm.toString(wrappedNativeToken)
                ),
                3
            );
        }

        // --- 4: CounterfactualDepositCCTP (deposit implementation for Circle CCTP) ---
        if (skip[4]) {
            console.log("[4] CounterfactualDepositCCTP: SKIPPED");
        } else {
            console.log("[4] Deploying CounterfactualDepositCCTP...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositCCTPCreate2.s.sol"),
                "DeployCounterfactualDepositCCTPCreate2",
                string.concat(
                    ' --sig "run(address,uint32)" ',
                    vm.toString(cctpPeriphery),
                    " ",
                    vm.toString(uint256(cctpDomain))
                ),
                4
            );
        }

        // --- 5: CounterfactualDepositOFT (deposit implementation for LayerZero OFT) ---
        if (skip[5]) {
            console.log("[5] CounterfactualDepositOFT: SKIPPED");
        } else {
            console.log("[5] Deploying CounterfactualDepositOFT...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployCounterfactualDepositOFTCreate2.s.sol"),
                "DeployCounterfactualDepositOFTCreate2",
                string.concat(
                    ' --sig "run(address,uint32)" ',
                    vm.toString(oftPeriphery),
                    " ",
                    vm.toString(uint256(oftEid))
                ),
                5
            );
        }

        // --- 6: AdminWithdrawManager (admin contract for managing withdrawals from clones) ---
        if (skip[6]) {
            console.log("[6] AdminWithdrawManager: SKIPPED");
        } else {
            console.log("[6] Deploying AdminWithdrawManager...");
            _runForgeScript(
                rpcUrl,
                broadcastFlag,
                string.concat(SCRIPT_DIR, "DeployAdminWithdrawManagerCreate2.s.sol"),
                "DeployAdminWithdrawManagerCreate2",
                string.concat(
                    ' --sig "run(address,address,address)" ',
                    vm.toString(owner),
                    " ",
                    vm.toString(directWithdrawer),
                    " ",
                    vm.toString(signer)
                ),
                6
            );
        }

        console.log("============================================");
        console.log("All deployments complete!");
        console.log("============================================");
    }

    /// @dev Invokes a single deploy script via `forge script` using vm.ffi().
    function _runForgeScript(
        string memory rpcUrl,
        string memory broadcastFlag,
        string memory scriptPath,
        string memory contractName,
        string memory sigArgs,
        uint256 index
    ) internal {
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

        string[] memory args = new string[](3);
        args[0] = "bash";
        args[1] = "-c";
        args[2] = cmd;
        vm.ffi(args);

        console.log("[%d] Done.", index);
    }

    /// @dev Predicts the CREATE2 address for a given salt and initCode.
    function _predictCreate2(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xff), StdConstants.CREATE2_FACTORY, salt, keccak256(initCode))
                        )
                    )
                )
            );
    }

    /// @dev Parses the SKIP env var (comma-separated indices like "4,5") into a boolean array.
    function _parseSkipList() internal view returns (bool[TOTAL_DEPLOYMENTS] memory skip) {
        string memory skipEnv = vm.envOr("SKIP", string(""));
        if (bytes(skipEnv).length == 0) return skip;

        bytes memory raw = bytes(skipEnv);
        for (uint256 i = 0; i < raw.length; i++) {
            if (raw[i] == ",") continue;
            uint8 digit = uint8(raw[i]) - 48; // ASCII '0' = 48
            require(digit < TOTAL_DEPLOYMENTS, "Invalid skip index");
            skip[digit] = true;
        }
    }
}
