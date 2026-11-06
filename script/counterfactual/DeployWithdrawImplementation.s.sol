// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { WithdrawImplementation } from "../../contracts/periphery/counterfactual/WithdrawImplementation.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployWithdrawImplementation.s.sol:DeployWithdrawImplementation --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployWithdrawImplementation is CounterfactualConfig {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Resolve the salt (which lazily loads config via file-reading cheatcodes) BEFORE startBroadcast.
        // Constructing the StdConfig helper inside the broadcast region breaks forge's on-chain simulation.
        bytes32 salt = _deploySalt();
        bytes memory initCode = type(WithdrawImplementation).creationCode;

        console.log("Deploying WithdrawImplementation via CREATE2...");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(salt, initCode);
        vm.stopBroadcast();

        console.log("WithdrawImplementation deployed to:", deployed);
    }
}
