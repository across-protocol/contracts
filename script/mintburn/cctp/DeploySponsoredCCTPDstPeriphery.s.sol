// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";

import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";
import { DonationBox } from "../../../contracts/chain-adapters/DonationBox.sol";
import { SponsoredCCTPDstPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPDstPeriphery.sol";

// Deploy: forge script script/mintburn/cctp/114DeploySponsoredCCTPDstPeriphery.sol:DeploySponsoredCCTPDstPeriphery --rpc-url <network> -vvvv
contract DeploySponsoredCCTPDstPeriphery is DeploymentUtils {
    function run() external {
        console.log("Deploying SponsoredCCTPDstPeriphery...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        _loadConfig("./script/mintburn/cctp/config.toml", true);

        address cctpMessageTransmitter = config.get("cctpMessageTransmitter").toAddress();

        vm.startBroadcast(deployerPrivateKey);

        DonationBox donationBox = DonationBox(config.get("donationBox").toAddress());
        console.log("DonationBox:", address(donationBox));

        // USDC on HyperEVM
        address baseToken = config.get("baseToken").toAddress();
        address multicallHandler = config.get("multicallHandler").toAddress();

        SponsoredCCTPDstPeriphery sponsoredCCTPDstPeriphery = new SponsoredCCTPDstPeriphery(
            cctpMessageTransmitter,
            deployer,
            address(donationBox),
            baseToken,
            multicallHandler
        );

        console.log("SponsoredCCTPDstPeriphery deployed to:", address(sponsoredCCTPDstPeriphery));

        donationBox.grantRole(donationBox.WITHDRAWER_ROLE(), address(sponsoredCCTPDstPeriphery));

        console.log("DonationBox WITHDRAWER_ROLE granted to:", address(sponsoredCCTPDstPeriphery));

        vm.stopBroadcast();
    }
}
