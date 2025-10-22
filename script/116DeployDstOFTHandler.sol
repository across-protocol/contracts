// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { DonationBox } from "../contracts/chain-adapters/DonationBox.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";
import { DstOFTHandler } from "../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";

// Deploy: forge script script/116DeployDstOFTHandler.sol:DeployDstOFTHandler --rpc-url <network> -vvvv
contract DeployDstOFTHandler is Script, Test, DeploymentUtils {
    function run() external {
        console.log("Deploying DstOFTHandler...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        vm.startBroadcast(deployerPrivateKey);

        address oftEndpoint = getL2Address(block.chainid, "oftEndpoint");
        address ioft = 0x904861a24F30EC96ea7CFC3bE9EA4B476d237e98;

        address baseToken = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
        uint32 coreIndex = 268;
        bool canBeUsedForAccountActivation = true;
        uint64 accountActivationFeeCore = 100000000;
        uint64 bridgeSafetyBufferCore = 1_000_000_000_00000000; // 1billion USDC (8 decimals)
        address multicallHandler = getL2Address(block.chainid, "multicallHandler");

        DonationBox donationBox = new DonationBox();

        DstOFTHandler dstOFTHandler = new DstOFTHandler(
            oftEndpoint,
            ioft,
            address(donationBox),
            baseToken,
            multicallHandler
        );
        console.log("DstOFTHandler deployed to:", address(dstOFTHandler));

        donationBox.transferOwnership(address(dstOFTHandler));

        console.log("DonationBox ownership transferred to:", address(dstOFTHandler));

        vm.stopBroadcast();
    }
}
