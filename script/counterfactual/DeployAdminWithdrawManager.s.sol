// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployAdminWithdrawManager.s.sol:DeployAdminWithdrawManager \
//      --sig "run(address,address,address)" <owner> <directWithdrawer> <signer> \
//      --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployAdminWithdrawManager is Script, Test {
    function run(address owner, address directWithdrawer, address signer) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envOr("DEPLOYER_INDEX", uint256(0))));

        require(owner != address(0), "Owner cannot be zero address");
        require(directWithdrawer != address(0), "Direct withdrawer cannot be zero address");
        require(signer != address(0), "Signer cannot be zero address");

        console.log("Deploying AdminWithdrawManager...");
        console.log("Chain ID:", block.chainid);
        console.log("Owner:", owner);
        console.log("Direct withdrawer:", directWithdrawer);
        console.log("Signer:", signer);

        vm.startBroadcast(deployerPrivateKey);

        AdminWithdrawManager manager = new AdminWithdrawManager(owner, directWithdrawer, signer);

        console.log("AdminWithdrawManager deployed to:", address(manager));

        vm.stopBroadcast();
    }
}
