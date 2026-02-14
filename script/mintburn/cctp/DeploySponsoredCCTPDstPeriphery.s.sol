// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";

import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";
import { DonationBox } from "../../../contracts/chain-adapters/DonationBox.sol";
import { SponsoredCCTPDstPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPDstPeriphery.sol";

// How to run:
// 1. source .env (needs MNEMONIC="x x x ... x")
// 2. Simulate: forge script script/mintburn/cctp/DeploySponsoredCCTPDstPeriphery.s.sol:DeploySponsoredCCTPDstPeriphery --rpc-url <network> -vvvv
// 3. Deploy:   forge script script/mintburn/cctp/DeploySponsoredCCTPDstPeriphery.s.sol:DeploySponsoredCCTPDstPeriphery --rpc-url <network> --broadcast --verify -vvvv
contract DeploySponsoredCCTPDstPeriphery is DeploymentUtils {
    function run() external {
        console.log("Deploying SponsoredCCTPDstPeriphery...");
        console.log("Chain ID:", block.chainid);
        require(
            block.chainid == 999 || block.chainid == 1,
            "Dst periphery must be deployed on HyperEVM (chain 999) or Ink (chain 57073)"
        );

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        _loadConfig("./script/mintburn/cctp/config.toml", true);

        address cctpMessageTransmitter = config.get("cctpMessageTransmitter").toAddress();
        address baseToken = config.get("baseToken").toAddress();
        address multicallHandler = config.get("multicallHandler").toAddress();

        vm.startBroadcast(deployerPrivateKey);

        DonationBox donationBox = new DonationBox();
        console.log("DonationBox deployed to:", address(donationBox));

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

        // Post-deployment verification.
        assertEq(address(sponsoredCCTPDstPeriphery.cctpMessageTransmitter()), cctpMessageTransmitter);
        assertEq(sponsoredCCTPDstPeriphery.baseToken(), baseToken);
        assertEq(sponsoredCCTPDstPeriphery.signer(), deployer);
        assertEq(donationBox.owner(), address(sponsoredCCTPDstPeriphery));
    }
}
