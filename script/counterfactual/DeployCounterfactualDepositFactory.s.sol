// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositFactory } from "../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";

// The factory has no constructor args, so its address is the same on every chain for a given salt.
// It is the CREATE2 deployer of all clones, so it MUST be uniform across chains — keep the salt
// (config.toml top-level `deploySalt`, default bytes32(0)) identical everywhere.
//
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositFactory.s.sol:DeployCounterfactualDepositFactory --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositFactory is CounterfactualConfig {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        bytes memory initCode = type(CounterfactualDepositFactory).creationCode;

        console.log("Deploying CounterfactualDepositFactory via CREATE2...");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(_deploySalt(), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositFactory deployed to:", deployed);
    }
}
