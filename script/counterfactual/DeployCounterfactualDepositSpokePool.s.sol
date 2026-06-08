// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import {
    CounterfactualDepositSpokePoolUsdc,
    CounterfactualDepositSpokePoolNative
} from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";

// Deploys the SpokePool leaf implementations. CounterfactualDepositSpokePool is now abstract; the concrete
// variants are CounterfactualDepositSpokePoolUsdc (input token = beacon.usdc()) and
// CounterfactualDepositSpokePoolNative (input = native, wrapped via beacon.wrappedNativeToken()). Both have
// no-arg constructors — the SpokePool, wrapped native token and fee signer are resolved from the
// CounterfactualBeacon at runtime — so each gets the SAME CREATE2 address on every chain.
//
// How to run (zero-arg):
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositSpokePool.s.sol:DeployCounterfactualDepositSpokePool \
//      --rpc-url $NODE_URL -vvvv
// 3. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositSpokePool is CounterfactualConfig {
    /// @notice Zero-arg entry point: deploys both the USDC and native SpokePool variants.
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);

        console.log("Deploying CounterfactualDepositSpokePool variants via CREATE2...");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);
        address usdc = _deployCreate2(bytes32(0), type(CounterfactualDepositSpokePoolUsdc).creationCode);
        address native = _deployCreate2(bytes32(0), type(CounterfactualDepositSpokePoolNative).creationCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositSpokePoolUsdc deployed to:  ", usdc);
        console.log("CounterfactualDepositSpokePoolNative deployed to:", native);
    }
}
