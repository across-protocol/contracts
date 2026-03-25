// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { TransferProxy } from "../contracts/TransferProxy.sol";
import { Constants } from "./utils/Constants.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/DeployTransferProxy.s.sol:DeployTransferProxy --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/DeployTransferProxy.s.sol:DeployTransferProxy --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeployTransferProxy is Script, Test, Constants {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        vm.startBroadcast(deployerPrivateKey);

        bytes32 salt = bytes32(uint256(0x1234));
        TransferProxy transferProxy = new TransferProxy{ salt: salt }();

        console.log("Chain ID:", block.chainid);
        console.log("TransferProxy deployed to:", address(transferProxy));

        vm.stopBroadcast();
    }
}
