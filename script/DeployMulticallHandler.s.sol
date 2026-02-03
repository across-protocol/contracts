// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { MulticallHandler } from "../contracts/handlers/MulticallHandler.sol";
import { Constants } from "./utils/Constants.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/008DeployMulticallHandler.s.sol:DeployMulticallHandler --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/008DeployMulticallHandler.s.sol:DeployMulticallHandler --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployMulticallHandler is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        vm.startBroadcast(deployerPrivateKey);

        bytes32 salt = bytes32(uint256(0x12345678));
        MulticallHandler multicallHandler = new MulticallHandler{ salt: salt }();

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Multicall handler deployed to:", address(multicallHandler));

        vm.stopBroadcast();
    }
}
