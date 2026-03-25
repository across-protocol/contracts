// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";

import { SponsoredCCTPSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";

// How to run:
// 1. source .env (needs MNEMONIC="x x x ... x")
// 2. Simulate: forge script script/mintburn/cctp/DeploySponsoredCCTPSrcPeriphery.s.sol:DeploySponsoredCCTPSrcPeriphery --rpc-url <network> -vvvv
// 3. Deploy:   forge script script/mintburn/cctp/DeploySponsoredCCTPSrcPeriphery.s.sol:DeploySponsoredCCTPSrcPeriphery --rpc-url <network> --broadcast --verify -vvvv
contract DeploySponsoredCCTPSrcPeriphery is DeploymentUtils {
    function run() external {
        console.log("Deploying SponsoredCCTPSrcPeriphery...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        _loadConfig("./script/mintburn/cctp/config.toml", true);

        address cctpTokenMessenger = config.get("cctpTokenMessenger").toAddress();
        uint32 sourceDomain = config.get("cctpDomainId").toUint32();

        vm.startBroadcast(deployerPrivateKey);

        SponsoredCCTPSrcPeriphery sponsoredCCTPSrcPeriphery = new SponsoredCCTPSrcPeriphery(
            cctpTokenMessenger,
            sourceDomain,
            deployer
        );

        console.log("SponsoredCCTPSrcPeriphery deployed to:", address(sponsoredCCTPSrcPeriphery));

        vm.stopBroadcast();

        config.set("sponsoredCCTPSrcPeriphery", address(sponsoredCCTPSrcPeriphery));

        // Post-deployment verification.
        assertEq(address(sponsoredCCTPSrcPeriphery.cctpTokenMessenger()), cctpTokenMessenger);
        assertEq(sponsoredCCTPSrcPeriphery.sourceDomain(), sourceDomain);
        assertEq(sponsoredCCTPSrcPeriphery.signer(), deployer);
        assertEq(sponsoredCCTPSrcPeriphery.owner(), deployer);
    }
}
