// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { SpokePoolPeriphery, SwapProxy } from "../contracts/SpokePoolPeriphery.sol";
import { Constants } from "./utils/Constants.sol";
import { IPermit2 } from "../contracts/external/interfaces/IPermit2.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/010DeploySpokePoolPeriphery.s.sol:DeploySpokePoolPeriphery --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/010DeploySpokePoolPeriphery.s.sol:DeploySpokePoolPeriphery --rpc-url $NODE_URL_1 --broadcast --verify -vvvv
contract DeploySpokePoolPeriphery is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;
        IPermit2 permit2 = IPermit2(getPermit2(chainId));

        vm.startBroadcast(deployerPrivateKey);

        bytes32 salt = bytes32(uint256(0x1235));
        SpokePoolPeriphery spokePoolPeriphery = new SpokePoolPeriphery{ salt: salt }(permit2);

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Permit2:", address(permit2));
        console.log("Spoke pool periphery deployed to:", address(spokePoolPeriphery));

        vm.stopBroadcast();
    }
}

contract DeploySwapProxy is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;
        address permit2 = getPermit2(chainId);

        vm.startBroadcast(deployerPrivateKey);

        bytes32 salt = bytes32(uint256(0x1235));
        SwapProxy swapProxy = new SwapProxy{ salt: salt }(permit2);

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Permit2:", address(permit2));
        console.log("Swap proxy deployed to:", address(swapProxy));

        vm.stopBroadcast();
    }
}
