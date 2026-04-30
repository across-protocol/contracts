// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// Deploys AdminWithdrawManager via CREATE2 with the deployer as owner and directWithdrawer, and the
// signer from config.toml (ensuring the same CREATE2 address on every chain since all three are
// global). Role transfers are handled by DeployAllCounterfactual after deployment.
//
// How to run:
// 1. Edit script/counterfactual/config.toml with signer per chain
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script script/counterfactual/DeployAdminWithdrawManager.s.sol:DeployAdminWithdrawManager \
//      --rpc-url $NODE_URL -vvvv
// 4. Deploy: append --broadcast --verify to the command above
contract DeployAdminWithdrawManager is CounterfactualConfig {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        _loadCounterfactualConfig();
        address signer = config.get("signer").toAddress();
        require(signer != address(0), "config: signer is zero");

        // Deploy with deployer as owner/directWithdrawer and config signer.
        // All three are global (not chain-specific), so CREATE2 address is the same everywhere.
        bytes memory initCode = abi.encodePacked(
            type(AdminWithdrawManager).creationCode,
            abi.encode(deployer, deployer, signer)
        );

        console.log("Deploying AdminWithdrawManager via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer (initial owner/directWithdrawer):", deployer);
        console.log("Signer:", signer);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("AdminWithdrawManager deployed to:", deployed);
    }
}
