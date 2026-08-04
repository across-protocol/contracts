// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { V5TestBeaconConfig } from "./V5TestBeaconConfig.sol";
import { CounterfactualBeaconBootstrap } from "../../../contracts/periphery/counterfactual/CounterfactualBeaconBootstrap.sol";
import { CounterfactualDepositFactory } from "../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";

// Prints the V5 test beacon stack's CREATE2 addresses without deploying anything. Read-only and offline (no
// --rpc-url needed): all four addresses are a function of the salt, the bootstrap's creation code and the
// deployer, none of which are chain-specific — which is exactly why the beacon proxy is identical on every
// chain and can be committed by address.
//
// This is step 1 of the deploy: V5's `CounterfactualDestinationExecutor` is constructor-bound to the beacon
// proxy, while the beacon bakes that executor as an immutable. Deploy the V5 executors against the proxy
// address printed here, put them in this folder's config.toml, then deploy the impl and the stack.
//
// How to run:
//   source .env   # MNEMONIC="x x x ... x"
//   FOUNDRY_PROFILE=counterfactual forge script \
//     script/counterfactual/v5-test-beacons/PredictV5TestBeacon.s.sol:PredictV5TestBeacon --sig "run()"
//
// Pass a salt to preview where a bump would land: --sig "run(bytes32)" 0x…
contract PredictV5TestBeacon is V5TestBeaconConfig {
    function run() external {
        _predict(bytes32(0));
    }

    /// @param salt Non-zero to override `[0.bytes32] deploySalt`; `bytes32(0)` uses the config value.
    function run(bytes32 salt) external {
        _predict(salt);
    }

    function _predict(bytes32 saltArg) internal {
        address deployer = vm.addr(vm.deriveKey(vm.envString("MNEMONIC"), 0));
        _overrideSalt(saltArg);
        bytes32 salt = _deploySalt();

        address proxy = _predictBeaconProxy(deployer);

        console.log("============================================");
        console.log("V5 TEST beacon stack - predicted addresses");
        console.log("============================================");
        console.log("Deployer / beacon owner:", deployer);
        console.log("Salt:                   ", vm.toString(salt));
        console.log(
            "Bootstrap:              ",
            _predictCreate2(salt, type(CounterfactualBeaconBootstrap).creationCode)
        );
        console.log("Beacon proxy:           ", proxy);
        console.log("Dispatcher:             ", _predictDispatcher(proxy));
        console.log(
            "Factory:                ",
            _predictCreate2(salt, abi.encodePacked(type(CounterfactualDepositFactory).creationCode, abi.encode(proxy)))
        );
        console.log("============================================");
        console.log("Bind the V5 executors to the beacon proxy above, then set them in config.toml.");
        console.log("The beacon IMPLEMENTATION is a plain CREATE (per-chain address), so it is not predicted.");
    }
}
