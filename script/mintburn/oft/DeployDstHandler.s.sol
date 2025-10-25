// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { DonationBox } from "../../../contracts/chain-adapters/DonationBox.sol";
import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";
import { DstOFTHandler } from "../../../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";
import { DstHandlerConfigurator } from "../../utils/DstHandlerConfigurator.sol";

contract DeployDstOFTHandler is Script, Test, DeploymentUtils, DstHandlerConfigurator {
    function run(string memory tokenKey, string memory baseTokenName) external {
        console.log("Deploying DstOFTHandler...");
        console.log("Chain ID:", block.chainid);

        _loadTokenConfig(tokenKey);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        address oftEndpoint = config.get("oft_endpoint").toAddress();
        address ioft = config.get("oft_messenger").toAddress();
        address baseToken = config.get("base_token").toAddress();
        address multicallHandler = config.get("multicall_handler").toAddress();
        require(oftEndpoint != address(0) && ioft != address(0) && baseToken != address(0), "config missing");

        vm.startBroadcast(deployerPrivateKey);

        DonationBox donationBox = new DonationBox();
        DstOFTHandler dstOFTHandler = new DstOFTHandler(
            oftEndpoint,
            ioft,
            address(donationBox),
            baseToken,
            multicallHandler
        );
        donationBox.transferOwnership(address(dstOFTHandler));

        console.log("DstOFTHandler deployed to:", address(dstOFTHandler));

        _configureCoreTokenInfo(baseTokenName, address(dstOFTHandler));
        _configureAuthorizedPeripheries(address(dstOFTHandler));

        vm.stopBroadcast();
    }
}
