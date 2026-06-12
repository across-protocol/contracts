// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";

// Deploys the CounterfactualDepositCCTP leaf implementation. Chain-identical (no constructor args; periphery,
// source domain, burn token and fee signer come from the CounterfactualBeacon at runtime), so it lands at the
// SAME CREATE2 address on every chain.
//
// How to run (zero-arg):
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositCCTP.s.sol:DeployCounterfactualDepositCCTP \
//      --rpc-url $NODE_URL -vvvv
// 3. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositCCTP is CounterfactualConfig {
    /// @notice Zero-arg entry point. Guards on CCTP support so we only deploy where the route exists.
    function run() external {
        require(hasCctpDomain(block.chainid), "Chain does not support CCTP");

        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);

        bytes memory initCode = type(CounterfactualDepositCCTP).creationCode;
        console.log("Deploying CounterfactualDepositCCTP via CREATE2...");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositCCTP deployed to:", deployed);
    }
}
