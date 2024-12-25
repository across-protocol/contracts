// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";

import { MulticallHandler } from "../contracts/handlers/MulticallHandler.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";

// How to run:
// 1. `source .env` where `.env has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/DeployMulticallHandler.s.sol:DeployMulticallHandler --rpc-url $NODE_URL_1-vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/DeployMulticallHandler.s.sol:DeployMulticallHandler --rpc-url $NODE_URL_1 --broadcast --verify -vvvv
contract DeployMulticallHandler is Script, Test {
    bytes32 constant salt = bytes32(uint256(0x00000000000000000000000000000000000000000000000000000012345678));

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        address handler = Create2.deploy(0, salt, type(MulticallHandler).creationCode);
    }
}
