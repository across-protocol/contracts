// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// Deploys AdminWithdrawManager via CREATE2 with the deployer as owner and directWithdrawer, and the
// signer from config.json (ensuring the same CREATE2 address on every chain since all three are
// global). After deployment, optionally transfers owner and directWithdrawer to the chain-specific
// address in config.json.
//
// How to run:
// 1. Edit script/counterfactual/config.json with signer, owner, and directWithdrawer
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script script/counterfactual/DeployAdminWithdrawManager.s.sol:DeployAdminWithdrawManager \
//      --sig "run(bool)" true \
//      --rpc-url $NODE_URL -vvvv
// 4. Deploy: append --broadcast --verify to the command above
contract DeployAdminWithdrawManager is CounterfactualConfig {
    /// @notice Deploy with deployer as all roles, then optionally transfer to config.json addresses.
    /// @param transferRoles If true, transfer owner/directWithdrawer/signer to config.json values.
    function run(bool transferRoles) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envOr("DEPLOYER_INDEX", uint256(0))));
        address deployer = vm.addr(deployerPrivateKey);
        address signer = _loadSigner();

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
        console.log("Transfer roles:", transferRoles);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);

        if (transferRoles) {
            OperationalConfig memory cfg = _loadOperationalConfig();
            AdminWithdrawManager manager = AdminWithdrawManager(deployed);

            console.log("Transferring owner + directWithdrawer to:", cfg.ownerAndDirectWithdrawer);

            if (cfg.ownerAndDirectWithdrawer != manager.directWithdrawer())
                manager.setDirectWithdrawer(cfg.ownerAndDirectWithdrawer);
            // Transfer ownership last (we lose owner privileges after this).
            if (cfg.ownerAndDirectWithdrawer != manager.owner())
                manager.transferOwnership(cfg.ownerAndDirectWithdrawer);
        } else {
            console.log("No role transfers (deployer retains all roles).");
        }

        vm.stopBroadcast();

        console.log("AdminWithdrawManager deployed to:", deployed);
    }
}
