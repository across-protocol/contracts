// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";

import { SponsoredCCTPSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";

// Deploy: forge script script/mintburn/cctp/113DeploySponsoredCCTPSrcPeriphery.sol:DeploySponsoredCCTPSrcPeriphery --rpc-url <network> -vvvv
contract DeploySponsoredCCTPSrcPeriphery is DeploymentUtils {
    function run() external {
        console.log("Deploying SponsoredCCTPSrcPeriphery...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        _loadConfig("./script/mintburn/cctp/config.toml", true);

        address cctpTokenMessenger = config.get("cctpTokenMessenger").toAddress();
        uint32 sourceDomain = config.get("cctpDomainId").toUint32();

        vm.startBroadcast(deployerPrivateKey);

        // TODO: use create2 for final deployment
        SponsoredCCTPSrcPeriphery sponsoredCCTPSrcPeriphery = new SponsoredCCTPSrcPeriphery(
            cctpTokenMessenger,
            sourceDomain,
            deployer
        );

        console.log("SponsoredCCTPSrcPeriphery deployed to:", address(sponsoredCCTPSrcPeriphery));
    }
}
