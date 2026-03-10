// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { CounterfactualDepositCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositCCTP.s.sol:DeployCounterfactualDepositCCTP \
//      --sig "run(address,uint32)" <srcPeriphery> <sourceDomain> \
//      --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositCCTP is Script, Test {
    function run(address srcPeriphery, uint32 sourceDomain) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envUint("DEPLOYER_INDEX")));

        require(srcPeriphery != address(0), "SrcPeriphery cannot be zero address");

        console.log("Deploying CounterfactualDepositCCTP...");
        console.log("Chain ID:", block.chainid);
        console.log("SrcPeriphery:", srcPeriphery);
        console.log("Source domain:", uint256(sourceDomain));

        vm.startBroadcast(deployerPrivateKey);

        CounterfactualDepositCCTP impl = new CounterfactualDepositCCTP(srcPeriphery, sourceDomain);

        console.log("CounterfactualDepositCCTP deployed to:", address(impl));

        vm.stopBroadcast();
    }
}
