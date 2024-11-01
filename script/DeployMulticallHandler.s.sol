// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { MulticallHandler } from "../contracts/handlers/MulticallHandler.sol";

// forge script script/DeployMulticallHandler.s.sol:DeployMulticallHandler --rpc-url $RPC_URL --broadcast --verify -vvvv <ADDITIONAL_VERIFICATION_INFO>
contract DeployMulticallHandler is Script {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        new MulticallHandler();
    }
}
