// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { CounterfactualDepositSpokePoolPeriphery } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePoolPeriphery.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositSpokePoolPeriphery.s.sol:DeployCounterfactualDepositSpokePoolPeriphery \
//      --sig "run(address,address,address)" <spokePoolPeriphery> <spokePool> <signer> \
//      --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositSpokePoolPeriphery is DeploymentUtils {
    function run(address spokePoolPeriphery, address spokePool, address signer) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envOr("DEPLOYER_INDEX", uint256(0))));

        require(spokePoolPeriphery != address(0), "SpokePoolPeriphery cannot be zero address");
        require(spokePool != address(0), "SpokePool cannot be zero address");
        require(signer != address(0), "Signer cannot be zero address");

        bytes memory initCode = abi.encodePacked(
            type(CounterfactualDepositSpokePoolPeriphery).creationCode,
            abi.encode(spokePoolPeriphery, spokePool, signer)
        );
        console.log("Deploying CounterfactualDepositSpokePoolPeriphery via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("SpokePoolPeriphery:", spokePoolPeriphery);
        console.log("SpokePool:", spokePool);
        console.log("Signer:", signer);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositSpokePoolPeriphery deployed to:", deployed);
    }
}
