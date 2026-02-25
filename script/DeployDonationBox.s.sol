// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { DonationBox } from "../contracts/chain-adapters/DonationBox.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/DeployDonationBox.s.sol:DeployDonationBox --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy by adding --broadcast --verify flags.
// 5. forge script script/DeployDonationBox.s.sol:DeployDonationBox --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployDonationBox is Script, Test {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy DonationBox (no constructor parameters needed, deployer becomes owner via Ownable)
        DonationBox donationBox = new DonationBox();

        // Log the deployed addresses
        console.log("Chain ID:", block.chainid);
        console.log("DonationBox deployed to:", address(donationBox));
        console.log("DonationBox owner:", donationBox.owner());

        vm.stopBroadcast();
    }
}
