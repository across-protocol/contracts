// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { HubPool } from "../contracts/HubPool.sol";
import { LpTokenFactory } from "../contracts/LpTokenFactory.sol";
import { FinderInterface } from "@uma/core/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";
import { Constants } from "./utils/Constants.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/001DeployHubPool.s.sol:DeployHubPool --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/001DeployHubPool.s.sol:DeployHubPool --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployHubPool is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        // Get the appropriate addresses for this chain
        WETH9Interface weth = getWrappedNativeToken(chainId);
        FinderInterface finder = FinderInterface(getL1Addresses(chainId).finder);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy LpTokenFactory first
        LpTokenFactory lpTokenFactory = new LpTokenFactory();

        // Deploy HubPool with the LpTokenFactory address
        HubPool hubPool = new HubPool(lpTokenFactory, finder, weth, address(0));

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("LpTokenFactory deployed to:", address(lpTokenFactory));
        console.log("HubPool deployed to:", address(hubPool));
        console.log("WETH address:", address(weth));
        console.log("Finder address:", address(finder));

        vm.stopBroadcast();
    }
}
