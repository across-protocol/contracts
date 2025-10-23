// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { DonationBox } from "../contracts/chain-adapters/DonationBox.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";
import { SponsoredOFTSrcPeriphery } from "../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";

// Deploy: forge script script/115DeploySrcOFTPeriphery.sol:DepoySrcOFTPeriphery --rpc-url <network> -vvvv
contract DepoySrcOFTPeriphery is Script, Test, DeploymentUtils {
    function run() external {
        console.log("Deploying SponsoredOFTSrcPeriphery...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        SponsoredOFTSrcPeriphery srcOftPeriphery = new SponsoredOFTSrcPeriphery(
            0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,
            0x14E4A1B13bf7F943c8ff7C51fb60FA964A298D92,
            30110,
            deployer
        );

        console.log("SponsoredOFTSrcPeriphery deployed to:", address(srcOftPeriphery));

        vm.stopBroadcast();
    }
}
