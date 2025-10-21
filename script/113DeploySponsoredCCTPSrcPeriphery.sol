// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

import { SponsoredCCTPSrcPeriphery } from "../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";

// Deploy: forge script script/114DeploySponsoredCCTPSrcPeriphery.sol:DeploySponsoredCCTPSrcPeriphery --rpc-url <network> -vvvv
contract DeploySponsoredCCTPSrcPeriphery is Script, Test, DeploymentUtils {
    function run() external {
        console.log("Deploying SponsoredCCTPSrcPeriphery...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        address cctpTokenMessenger = getL2Address(block.chainid, "cctpV2TokenMessenger");
        // Testnet
        // address cctpTokenMessenger = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;

        uint32 sourceDomain = getCircleDomainId(block.chainid);

        console.log("cctpTokenMessenger:", cctpTokenMessenger);
        console.log("sourceDomain:", sourceDomain);
        console.log("deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        SponsoredCCTPSrcPeriphery sponsoredCCTPSrcPeriphery = new SponsoredCCTPSrcPeriphery(
            cctpTokenMessenger,
            sourceDomain,
            deployer
        );

        console.log("SponsoredCCTPSrcPeriphery deployed to:", address(sponsoredCCTPSrcPeriphery));
    }
}
