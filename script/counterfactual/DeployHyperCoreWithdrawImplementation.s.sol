// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { HyperCoreWithdrawImplementation } from "../../contracts/periphery/counterfactual/HyperCoreWithdrawImplementation.sol";

// HyperEVM (chain 999) only — the CoreWriter/precompile addresses exist on no other chain.
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/counterfactual/DeployHyperCoreWithdrawImplementation.s.sol:DeployHyperCoreWithdrawImplementation --rpc-url $NODE_URL_999 -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast to the command above
contract DeployHyperCoreWithdrawImplementation is DeploymentUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        bytes memory initCode = type(HyperCoreWithdrawImplementation).creationCode;

        console.log("Deploying HyperCoreWithdrawImplementation via CREATE2...");
        console.log("Chain ID:", block.chainid);
        require(block.chainid == 999, "HyperCoreWithdrawImplementation is HyperEVM-only");

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("HyperCoreWithdrawImplementation deployed to:", deployed);
    }
}
