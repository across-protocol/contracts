// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositSpokePoolTr } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePoolTr.sol";

// Deploys the SpokePool leaf implementation. Input-token-agnostic (the leaf names its input token via the
// beacon getter selector `inputTokenGetter`; SpokePool, wrapped native token and fee signer come from the
// CounterfactualBeacon at runtime) and has no constructor args, so it lands at the SAME CREATE2 address on
// every EVM chain.
//
// On Tron (chainid 728126428) the `CounterfactualDepositSpokePoolTr` variant is deployed instead: it
// overrides `_safeTransfer` so Tron USDT's non-standard `transfer` (returns `false` on success) doesn't revert
// execution-fee payouts. It lands at a different CREATE2 address — merkle leaves for Tron must name it. The
// canonical Tron production deploy uses Tron's solc fork via
// `script/tron/counterfactual/tron-deploy-counterfactual-deposit-spokepool-tron.ts`; this Foundry branch is a
// defensive fallback if the script is run against a Tron RPC directly.
//
// How to run (zero-arg):
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositSpokePool.s.sol:DeployCounterfactualDepositSpokePool \
//      --rpc-url $NODE_URL -vvvv
// 3. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositSpokePool is CounterfactualConfig {
    /// @notice Tron mainnet chainid; selects the `CounterfactualDepositSpokePoolTr` variant.
    uint256 internal constant TRON_CHAIN_ID = 728126428;

    /// @notice Zero-arg entry point.
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);

        bool isTron = block.chainid == TRON_CHAIN_ID;
        bytes memory creationCode = isTron
            ? type(CounterfactualDepositSpokePoolTr).creationCode
            : type(CounterfactualDepositSpokePool).creationCode;
        string memory implName = isTron ? "CounterfactualDepositSpokePoolTr" : "CounterfactualDepositSpokePool";

        console.log("Deploying %s via CREATE2...", implName);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), creationCode);
        vm.stopBroadcast();

        console.log("%s deployed to:", implName);
        console.log(" ", deployed);
    }
}
