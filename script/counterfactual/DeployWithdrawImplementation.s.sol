// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { WithdrawImplementation } from "../../contracts/periphery/counterfactual/WithdrawImplementation.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployWithdrawImplementation.s.sol:DeployWithdrawImplementation --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployWithdrawImplementation is Script, Test {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envOr("DEPLOYER_INDEX", uint256(0))));

        console.log("Deploying WithdrawImplementation...");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        WithdrawImplementation impl = new WithdrawImplementation();

        console.log("WithdrawImplementation deployed to:", address(impl));

        vm.stopBroadcast();
    }
}
