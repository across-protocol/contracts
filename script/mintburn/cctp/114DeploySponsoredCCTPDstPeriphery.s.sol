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

        DonationBox donationBox = new DonationBox();
        console.log("DonationBox deployed to:", address(donationBox));

        // USDC on HyperEVM
        address baseToken = config.get("baseToken").toAddress();
        address multicallHandler = config.get("multicallHandler").toAddress();

        // TODO: use create2 for final deployment
        SponsoredCCTPDstPeriphery sponsoredCCTPDstPeriphery = new SponsoredCCTPDstPeriphery(
            cctpMessageTransmitter,
            deployer,
            address(donationBox),
            baseToken,
            multicallHandler
        );

        console.log("SponsoredCCTPDstPeriphery deployed to:", address(sponsoredCCTPDstPeriphery));

        donationBox.transferOwnership(address(sponsoredCCTPDstPeriphery));

        console.log("DonationBox ownership transferred to:", address(sponsoredCCTPDstPeriphery));

        vm.stopBroadcast();
    }
}
