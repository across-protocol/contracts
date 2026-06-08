// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositSpokePoolTr } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePoolTr.sol";

// Deploys the SpokePool leaf implementation. It is input-token-agnostic: the leaf names its input token by
// the beacon getter selector (`inputTokenGetter`), and the SpokePool, wrapped native token and fee signer
// are resolved from the CounterfactualBeacon at runtime. With no constructor args it gets the SAME CREATE2
// address on every EVM chain.
//
// On Tron (chainid 728126428) the Tron-specific variant `CounterfactualDepositSpokePoolTr` is deployed
// instead: it overrides `_safeTransfer` so Tron USDT's non-standard `transfer` (which returns `false` on
// success) does not revert execution-fee payouts. The Tron variant lands at a different CREATE2 address —
// merkle leaves for Tron must name that address. Note: the canonical Tron production deploy uses Tron's
// solc fork via `script/tron/counterfactual/tron-deploy-counterfactual-deposit-spokepool-tron.ts`; this
// Foundry branch is the defensive path in case the script is invoked against a Tron RPC directly.
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
