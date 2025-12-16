// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { PermissionedMulticallHandler } from "../../contracts/handlers/PermissionedMulticallHandler.sol";

// Deploy: forge script script/mintburn/DeployPermissionedMulticallHandler.s.sol:DeployPermissionedMulticallHandler --rpc-url <network> -vvvv --broadcast
contract DeployPermissionedMulticallHandler is Script {
    function run() external {
        console.log("Deploying PermissionedMulticallHandler...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        PermissionedMulticallHandler handler = new PermissionedMulticallHandler(deployer);

        console.log("PermissionedMulticallHandler deployed to:", address(handler));
        console.log("Admin (DEFAULT_ADMIN_ROLE):", deployer);

        vm.stopBroadcast();
    }
}
