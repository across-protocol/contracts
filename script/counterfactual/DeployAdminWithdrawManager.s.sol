// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployAdminWithdrawManager.s.sol:DeployAdminWithdrawManager \
//      --sig "run(address,address,address)" <owner> <directWithdrawer> <signer> \
//      --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployAdminWithdrawManager is DeploymentUtils {
    function run(address owner, address directWithdrawer, address signer) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envOr("DEPLOYER_INDEX", uint256(0))));

        require(owner != address(0), "Owner cannot be zero address");
        require(directWithdrawer != address(0), "Direct withdrawer cannot be zero address");
        require(signer != address(0), "Signer cannot be zero address");

        bytes memory initCode = abi.encodePacked(
            type(AdminWithdrawManager).creationCode,
            abi.encode(owner, directWithdrawer, signer)
        );
        console.log("Deploying AdminWithdrawManager via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("Owner:", owner);
        console.log("Direct withdrawer:", directWithdrawer);
        console.log("Signer:", signer);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("AdminWithdrawManager deployed to:", deployed);
    }
}
