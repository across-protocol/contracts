// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { Create2DeployUtils } from "./Create2DeployUtils.sol";
import { CounterfactualDepositFactory } from "../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositFactoryCreate2.s.sol:DeployCounterfactualDepositFactoryCreate2 --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositFactoryCreate2 is Create2DeployUtils, Test {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envOr("DEPLOYER_INDEX", uint256(0))));

        bytes memory initCode = type(CounterfactualDepositFactory).creationCode;
        address predicted = _predictCreate2(bytes32(0), initCode);

        console.log("Deploying CounterfactualDepositFactory via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("Predicted address:", predicted);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositFactory deployed to:", deployed);
    }
}
