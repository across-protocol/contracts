// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { SpokePoolVerifier } from "../contracts/SpokePoolVerifier.sol";

// forge script script/DeploySpokePoolVerifier.s.sol:DeploySpokePoolVerifier --rpc-url $RPC_URL --broadcast --verify -vvvv <ADDITIONAL_VERIFICATION_INFO>
contract DeploySpokePoolVerifier is Script {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        new SpokePoolVerifier();
    }
}
