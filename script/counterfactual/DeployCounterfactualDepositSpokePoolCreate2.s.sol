// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { Create2DeployUtils } from "./Create2DeployUtils.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositSpokePoolCreate2.s.sol:DeployCounterfactualDepositSpokePoolCreate2 \
//      --sig "run(address,address,address)" <spokePool> <signer> <wrappedNativeToken> \
//      --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositSpokePoolCreate2 is Create2DeployUtils, Test {
    function run(address spokePool, address signer, address wrappedNativeToken) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envOr("DEPLOYER_INDEX", uint256(0))));

        require(spokePool != address(0), "SpokePool cannot be zero address");
        require(signer != address(0), "Signer cannot be zero address");
        require(wrappedNativeToken != address(0), "Wrapped native token cannot be zero address");

        bytes memory initCode = abi.encodePacked(
            type(CounterfactualDepositSpokePool).creationCode,
            abi.encode(spokePool, signer, wrappedNativeToken)
        );
        address predicted = _predictCreate2(bytes32(0), initCode);

        console.log("Deploying CounterfactualDepositSpokePool via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("SpokePool:", spokePool);
        console.log("Signer:", signer);
        console.log("Wrapped native token:", wrappedNativeToken);
        console.log("Predicted address:", predicted);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositSpokePool deployed to:", deployed);
    }
}
