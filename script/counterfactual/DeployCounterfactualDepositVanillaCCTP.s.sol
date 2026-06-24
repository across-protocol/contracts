// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositVanillaCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositVanillaCCTP.sol";

// Deploys the CounterfactualDepositVanillaCCTP leaf implementation (vanilla, non-sponsored Circle CCTP v2).
// Chain-identical (no constructor args; TokenMessenger, burn token (USDC) and fee signer come from the
// CounterfactualBeacon at runtime), so it lands at the SAME CREATE2 address on every chain.
//
// How to run (zero-arg):
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositVanillaCCTP.s.sol:DeployCounterfactualDepositVanillaCCTP \
//      --rpc-url $NODE_URL -vvvv
// 3. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositVanillaCCTP is CounterfactualConfig {
    /// @notice Zero-arg entry point.
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);

        bytes memory initCode = type(CounterfactualDepositVanillaCCTP).creationCode;
        console.log("Deploying CounterfactualDepositVanillaCCTP via CREATE2...");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositVanillaCCTP deployed to:", deployed);
    }
}
