// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositSpokePool.s.sol:DeployCounterfactualDepositSpokePool \
//      --sig "run(address,address,address)" <spokePool> <signer> <wrappedNativeToken> \
//      --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositSpokePool is Script, Test {
    function run(address spokePool, address signer, address wrappedNativeToken) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envOr("DEPLOYER_INDEX", uint256(0))));

        require(spokePool != address(0), "SpokePool cannot be zero address");
        require(signer != address(0), "Signer cannot be zero address");
        require(wrappedNativeToken != address(0), "Wrapped native token cannot be zero address");

        console.log("Deploying CounterfactualDepositSpokePool...");
        console.log("Chain ID:", block.chainid);
        console.log("SpokePool:", spokePool);
        console.log("Signer:", signer);
        console.log("Wrapped native token:", wrappedNativeToken);

        vm.startBroadcast(deployerPrivateKey);

        CounterfactualDepositSpokePool impl = new CounterfactualDepositSpokePool(spokePool, signer, wrappedNativeToken);

        console.log("CounterfactualDepositSpokePool deployed to:", address(impl));

        vm.stopBroadcast();
    }
}
