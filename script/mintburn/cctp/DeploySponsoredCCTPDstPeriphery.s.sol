// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";

import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";
import { DonationBox } from "../../../contracts/chain-adapters/DonationBox.sol";
import { SponsoredCCTPDstPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPDstPeriphery.sol";
import { PermissionedMulticallHandler } from "../../../contracts/handlers/PermissionedMulticallHandler.sol";

// How to run:
// 1. source .env (needs MNEMONIC="x x x ... x")
// 2. Simulate: forge script script/mintburn/cctp/DeploySponsoredCCTPDstPeriphery.s.sol:DeploySponsoredCCTPDstPeriphery --rpc-url <network> -vvvv
// 3. Deploy:   forge script script/mintburn/cctp/DeploySponsoredCCTPDstPeriphery.s.sol:DeploySponsoredCCTPDstPeriphery --rpc-url <network> --broadcast --verify -vvvv
contract DeploySponsoredCCTPDstPeriphery is DeploymentUtils {
    string internal constant CONFIG_PATH = "./script/mintburn/cctp/config.toml";

    function run() external virtual {
        _loadConfig(CONFIG_PATH, true);

        address baseToken = config.get("usdc").toAddress();
        require(baseToken != address(0), "baseToken cannot be zero");

        console.log("Deploying SponsoredCCTPDstPeriphery...");
        console.log("Chain ID:", block.chainid);
        console.log("Token name:", "usdc");
        console.log("Base token:", baseToken);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        address cctpMessageTransmitter = config.get("cctpMessageTransmitter").toAddress();
        address cctpTokenMessenger = config.get("cctpTokenMessenger").toAddress();
        address sponsoredCCTPSrcPeriphery = config.get("sponsoredCCTPSrcPeriphery").toAddress();

        vm.startBroadcast(deployerPrivateKey);

        PermissionedMulticallHandler multicallHandler = new PermissionedMulticallHandler(deployer);
        console.log("MulticallHandler", address(multicallHandler));

        DonationBox donationBox = new DonationBox();
        console.log("DonationBox:", address(donationBox));

        SponsoredCCTPDstPeriphery sponsoredCCTPDstPeriphery = new SponsoredCCTPDstPeriphery(
            cctpMessageTransmitter,
            cctpTokenMessenger,
            deployer,
            address(donationBox),
            baseToken,
            address(multicallHandler)
        );

        console.log("SponsoredCCTPDstPeriphery deployed to:", address(sponsoredCCTPDstPeriphery));

        donationBox.grantRole(donationBox.WITHDRAWER_ROLE(), address(sponsoredCCTPDstPeriphery));

        console.log("DonationBox WITHDRAWER_ROLE granted to:", address(sponsoredCCTPDstPeriphery));

        multicallHandler.grantRole(multicallHandler.WHITELISTED_CALLER_ROLE(), address(sponsoredCCTPDstPeriphery));

        console.log("MulticallHandler WHITELISTED_CALLER_ROLE granted to:", address(sponsoredCCTPDstPeriphery));

        sponsoredCCTPDstPeriphery.grantRole(sponsoredCCTPDstPeriphery.DIRECT_CALLER_ROLE(), sponsoredCCTPSrcPeriphery);

        console.log("SponsoredCCTPDstPeriphery DIRECT_CALLER_ROLE to:", sponsoredCCTPSrcPeriphery);

        vm.stopBroadcast();

        config.set("sponsoredCCTPDstPeriphery", address(sponsoredCCTPDstPeriphery));
        config.set("multicallHandler", address(multicallHandler));

        // Post-deployment verification.
        assertEq(address(sponsoredCCTPDstPeriphery.cctpMessageTransmitter()), cctpMessageTransmitter);
        assertEq(address(sponsoredCCTPDstPeriphery.cctpTokenMessenger()), cctpTokenMessenger);
        assertEq(sponsoredCCTPDstPeriphery.baseToken(), baseToken);
        assertEq(sponsoredCCTPDstPeriphery.signer(), deployer);
        assertTrue(donationBox.hasRole(donationBox.WITHDRAWER_ROLE(), address(sponsoredCCTPDstPeriphery)));
    }
}
