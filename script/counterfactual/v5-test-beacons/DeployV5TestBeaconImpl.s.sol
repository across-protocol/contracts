// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { V5TestBeaconConfig } from "./V5TestBeaconConfig.sol";
import {
    CounterfactualBeacon,
    CounterfactualChainConfig
} from "../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";

// Deploys the chain-specific V5 TEST beacon IMPLEMENTATION: a `CounterfactualBeacon` whose immutables are
// built from script/counterfactual/v5-test-beacons/config.toml (plus the shared constants.json /
// deployed-addresses.json resolvers, for the V4 fields that file does not override). Same contract and same
// mechanics as the production DeployCounterfactualBeaconImpl — only the config source differs.
//
// Plain CREATE, so the impl gets a per-chain address (it sits behind the address-stable proxy). The salt is
// therefore irrelevant here; it matters only to DeployV5TestBeacon, which deploys the proxy.
//
// ORDERING. The impl bakes `destinationExecutor` (and the other V5 executors) as immutables, while V5's
// `CounterfactualDestinationExecutor` is itself constructor-bound to the beacon PROXY. The cycle resolves in
// one direction only:
//   1. `PredictV5TestBeacon.s.sol` -> the proxy address (a function of the salt, bootstrap and deployer only).
//   2. Deploy the V5 executors from the V5 repo against that predicted proxy.
//   3. Paste their addresses into this folder's config.toml.
//   4. This script.
//   5. `DeployV5TestBeacon.s.sol` (bootstrap, proxy, upgrade to this impl, dispatcher, factory).
// Steps 1-3 can be skipped on a first pass: the executor getters then bake as `address(0)` and every V5 route
// fails closed with `RouteNotConfigured` until a new impl is deployed and the proxy upgraded to it.
//
// How to run:
// 1. Edit script/counterfactual/v5-test-beacons/config.toml for this chain (getter name = config key).
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. FOUNDRY_PROFILE=counterfactual forge script \
//      script/counterfactual/v5-test-beacons/DeployV5TestBeaconImpl.s.sol:DeployV5TestBeaconImpl \
//      --rpc-url base -vvvv
// 4. Review the logged config dump (it is immutable once deployed), then append --broadcast --verify
contract DeployV5TestBeaconImpl is V5TestBeaconConfig {
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);

        // Resolve the chain config (which lazily loads config via file-reading cheatcodes) BEFORE
        // startBroadcast. Constructing the StdConfig helper inside the broadcast region breaks forge's
        // on-chain simulation.
        CounterfactualChainConfig memory chainConfig = _buildV5TestChainConfig();

        console.log("============================================");
        console.log("V5 TEST CounterfactualBeacon implementation");
        console.log("============================================");
        console.log("Chain ID:", block.chainid);

        _warnIfDestinationExecutorBoundElsewhere(
            chainConfig.destinationExecutor,
            _predictBeaconProxy(vm.addr(deployerPrivateKey))
        );

        vm.startBroadcast(deployerPrivateKey);
        address beaconImpl = address(new CounterfactualBeacon(chainConfig));
        vm.stopBroadcast();

        console.log("V5 test beacon impl:", beaconImpl);
        console.log("Next: run DeployV5TestBeacon to point the test proxy at this impl.");
    }

    /// @dev The configured `destinationExecutor` is constructor-bound to a beacon; if that is not the proxy
    ///      THIS folder deploys, the two halves disagree — the executor would read `signer()`/`stablePrice()`
    ///      off a different beacon. The usual cause is a salt bump (new proxy, executors still bound to the
    ///      old one). Warn rather than revert: the getter is advisory, the value is legitimately zero before
    ///      the V5 stack exists, and a non-conforming executor ABI must not block the deploy.
    function _warnIfDestinationExecutorBoundElsewhere(address executor, address expectedProxy) private view {
        if (executor == address(0) || executor.code.length == 0) return;
        (bool ok, bytes memory ret) = executor.staticcall(abi.encodeWithSignature("beacon()"));
        if (!ok || ret.length != 32) {
            console.log("NOTE: destinationExecutor has no readable beacon(); cannot verify its binding.");
            return;
        }
        address boundBeacon = abi.decode(ret, (address));
        if (boundBeacon == expectedProxy) {
            console.log("destinationExecutor is bound to this beacon proxy:", boundBeacon);
            return;
        }
        console.log("--------------------------------------------");
        console.log("WARNING: destinationExecutor is bound to a DIFFERENT beacon.");
        console.log("  executor:      ", executor);
        console.log("  its beacon():  ", boundBeacon);
        console.log("  this proxy:    ", expectedProxy);
        console.log("Check the salt, or redeploy the executor against this proxy, before broadcasting.");
        console.log("--------------------------------------------");
    }
}
