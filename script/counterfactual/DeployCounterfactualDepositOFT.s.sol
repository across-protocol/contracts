// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { CounterfactualDepositOFT } from "../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositOFT.s.sol:DeployCounterfactualDepositOFT \
//      --sig "run(address,uint32)" <oftSrcPeriphery> <srcEid> \
//      --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositOFT is Script, Test {
    function run(address oftSrcPeriphery, uint32 srcEid) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        require(oftSrcPeriphery != address(0), "OFT SrcPeriphery cannot be zero address");

        console.log("Deploying CounterfactualDepositOFT...");
        console.log("Chain ID:", block.chainid);
        console.log("OFT SrcPeriphery:", oftSrcPeriphery);
        console.log("Source EID:", uint256(srcEid));

        vm.startBroadcast(deployerPrivateKey);

        CounterfactualDepositOFT impl = new CounterfactualDepositOFT(oftSrcPeriphery, srcEid);

        console.log("CounterfactualDepositOFT deployed to:", address(impl));

        vm.stopBroadcast();
    }
}
