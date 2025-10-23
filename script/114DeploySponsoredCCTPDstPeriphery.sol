// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { DeploymentUtils } from "./utils/DeploymentUtils.sol";
import { DonationBox } from "../contracts/chain-adapters/DonationBox.sol";
import { SponsoredCCTPDstPeriphery } from "../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPDstPeriphery.sol";

// Deploy: forge script script/114DeploySponsoredCCTPDstPeriphery.sol:DeploySponsoredCCTPDstPeriphery --rpc-url <network> -vvvv
contract DeploySponsoredCCTPDstPeriphery is Script, Test, DeploymentUtils {
    function run() external {
        console.log("Deploying SponsoredCCTPDstPeriphery...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        address cctpMessageTransmitter = getL2Address(block.chainid, "cctpV2MessageTransmitter");
        // address cctpMessageTransmitter = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;

        vm.startBroadcast(deployerPrivateKey);

        DonationBox donationBox = new DonationBox();
        console.log("DonationBox deployed to:", address(donationBox));

        // USDC on HyperEVM Testnet
        // address baseToken = 0x2B3370eE501B4a559b57D449569354196457D8Ab;
        // USDC on HyperEVM Mainnet
        address baseToken = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
        uint32 coreIndex = 0;
        bool canBeUsedForAccountActivation = true;
        uint64 accountActivationFeeCore = 100000000; // 1 USDC
        uint64 bridgeSafetyBufferCore = 1_000_000_00000000; // 1mil USDC (8 decimals)

        SponsoredCCTPDstPeriphery sponsoredCCTPDstPeriphery = new SponsoredCCTPDstPeriphery(
            cctpMessageTransmitter,
            deployer,
            address(donationBox),
            baseToken,
            address(0)
        );

        console.log("SponsoredCCTPDstPeriphery deployed to:", address(sponsoredCCTPDstPeriphery));

        donationBox.transferOwnership(address(sponsoredCCTPDstPeriphery));

        console.log("DonationBox ownership transferred to:", address(sponsoredCCTPDstPeriphery));

        vm.stopBroadcast();
    }
}
