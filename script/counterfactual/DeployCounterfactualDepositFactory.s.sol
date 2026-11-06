// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositFactory } from "../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";

// Deploys the CounterfactualDepositFactory via CREATE2. The factory embeds the beacon proxy as its immutable
// `BEACON` (every clone it deploys points there), so its init code includes the chain-invariant beacon proxy
// address as a constructor arg => identical init code => same factory address on every chain. The beacon must
// be deployed (or at least predicted) first; this recomputes the proxy address the same way DeployCounterfactualBeacon does.
//
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositFactory.s.sol:DeployCounterfactualDepositFactory --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositFactory is CounterfactualConfig {
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Resolve salt + beacon (both lazily load config via file-reading cheatcodes) BEFORE startBroadcast;
        // constructing the StdConfig helper inside the broadcast region breaks forge's on-chain simulation.
        bytes32 salt = _deploySalt();
        address beacon = _predictBeaconProxy(deployer);
        bytes memory initCode = abi.encodePacked(type(CounterfactualDepositFactory).creationCode, abi.encode(beacon));

        console.log("Deploying CounterfactualDepositFactory via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("Beacon:  ", beacon);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(salt, initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositFactory deployed to:", deployed);
    }
}
