// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/console.sol";

import { DonationBox } from "../../../contracts/chain-adapters/DonationBox.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/mintburn/cctp/DeployDonationBox.s.sol:DeployDonationBox --rpc-url <network> -vvvv
// 3. Verify simulation works
// 4. Deploy: forge script script/mintburn/cctp/DeployDonationBox.s.sol:DeployDonationBox --rpc-url <network> --broadcast --verify -vvvv
contract DeployDonationBox is Script {
    function run() external {
        console.log("Deploying DonationBox...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        DonationBox donationBox = new DonationBox();

        console.log("DonationBox deployed to:", address(donationBox));
        console.log("DEFAULT_ADMIN_ROLE granted to:", deployer);
        console.log("WITHDRAWER_ROLE granted to:", deployer);

        _loadConfig("./script/mintburn/cctp/config.toml", true);
        config.set("donationBox", address(donationBox));
        console.log("DonationBox address set in config to:", address(donationBox));

        vm.stopBroadcast();
    }

    /// @notice Grant WITHDRAWER_ROLE to an address on an existing DonationBox
    /// @dev Run with: forge script script/mintburn/cctp/DeployDonationBox.s.sol:DeployDonationBox --sig "grantWithdrawer(address,address)" <donationBox> <withdrawer> --rpc-url <network> --broadcast -vvvv
    function grantWithdrawer(address donationBoxAddr, address withdrawer) external {
        console.log("Granting WITHDRAWER_ROLE on DonationBox...");
        console.log("DonationBox:", donationBoxAddr);
        console.log("Withdrawer:", withdrawer);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        DonationBox donationBox = DonationBox(donationBoxAddr);

        vm.startBroadcast(deployerPrivateKey);

        donationBox.grantRole(donationBox.WITHDRAWER_ROLE(), withdrawer);

        console.log("WITHDRAWER_ROLE granted to:", withdrawer);

        vm.stopBroadcast();
    }

    /// @notice Revoke WITHDRAWER_ROLE from an address on an existing DonationBox
    /// @dev Run with: forge script script/mintburn/cctp/DeployDonationBox.s.sol:DeployDonationBox --sig "revokeWithdrawer(address,address)" <donationBox> <withdrawer> --rpc-url <network> --broadcast -vvvv
    function revokeWithdrawer(address donationBoxAddr, address withdrawer) external {
        console.log("Revoking WITHDRAWER_ROLE on DonationBox...");
        console.log("DonationBox:", donationBoxAddr);
        console.log("Withdrawer:", withdrawer);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        DonationBox donationBox = DonationBox(donationBoxAddr);

        vm.startBroadcast(deployerPrivateKey);

        donationBox.revokeRole(donationBox.WITHDRAWER_ROLE(), withdrawer);

        console.log("WITHDRAWER_ROLE revoked from:", withdrawer);

        vm.stopBroadcast();
    }
}
