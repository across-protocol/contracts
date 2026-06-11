// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import {
    CounterfactualBeacon,
    CounterfactualChainConfig
} from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";

// Deploys the chain-specific CounterfactualBeacon IMPLEMENTATION, baking this chain's
// CounterfactualChainConfig (SpokePool, bridge endpoints, fee signer, tokens, fee caps — resolved from
// constants.json + deployed-addresses.json + config.toml) into its immutables. The impl deliberately gets a
// per-chain address (plain CREATE) — it sits behind the address-stable beacon proxy managed by
// DeployCounterfactualBeacon.s.sol, which reads this script's broadcast run-latest.json for the most recent
// impl and `upgradeToAndCall`s the proxy to it.
//
// Run this script first on a fresh chain, and again whenever the chain config changes (the config is
// immutable on the impl, so a change means a new impl + a proxy upgrade); then run
// DeployCounterfactualBeacon to retarget the proxy.
//
// How to run:
// 1. Edit script/counterfactual/config.toml with the signer for this chain
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script script/counterfactual/DeployCounterfactualBeaconImpl.s.sol:DeployCounterfactualBeaconImpl \
//      --rpc-url $NODE_URL -vvvv
// 4. Deploy: append --broadcast --verify
contract DeployCounterfactualBeaconImpl is CounterfactualConfig {
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);

        // Resolve the chain config (which lazily loads config via file-reading cheatcodes) BEFORE
        // startBroadcast. Constructing the StdConfig helper inside the broadcast region breaks forge's
        // on-chain simulation.
        CounterfactualChainConfig memory chainConfig = _buildChainConfig();

        console.log("============================================");
        console.log("CounterfactualBeacon implementation deployment");
        console.log("============================================");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);
        address beaconImpl = address(new CounterfactualBeacon(chainConfig));
        vm.stopBroadcast();

        console.log("Beacon impl:", beaconImpl);
        console.log("Next: run DeployCounterfactualBeacon to point the proxy at this impl.");
    }
}
