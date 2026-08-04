// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { V5TestBeaconConfig } from "./V5TestBeaconConfig.sol";
import { WithdrawImplementation } from "../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";

// Deploys `WithdrawImplementation` under the V5 TEST salt — the withdraw leaf every test clone's merkle tree
// includes, letting funds be recovered from a counterfactual address. Same contract and mechanics as the
// production DeployWithdrawImplementation; only the salt (and therefore the address) differs.
//
// WHY A SEPARATE DEPLOYMENT AT ALL. This contract holds no beacon and takes no constructor args, so the
// production deployment would work perfectly well with the test beacon — a route leaf names the withdraw
// implementation directly. It is deployed here purely so the test stack is self-contained under one salt: the
// V5 test tree can be built entirely from V5Test* addresses without reaching into production. Reusing the
// production address instead is a valid choice; just make sure the leaf names whichever one you meant.
//
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. FOUNDRY_PROFILE=counterfactual forge script \
//      script/counterfactual/v5-test-beacons/DeployV5TestWithdrawImplementation.s.sol:DeployV5TestWithdrawImplementation \
//      --sig "run()" --rpc-url base -vvvv
//    (two `run` overloads, so an explicit --sig is REQUIRED)
// 3. Deploy: append --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
contract DeployV5TestWithdrawImplementation is V5TestBeaconConfig {
    /// @notice Deploys with the salt from this folder's config.toml.
    function run() external {
        _run(bytes32(0));
    }

    /// @param salt Non-zero to override `[0.bytes32] deploySalt`; `bytes32(0)` uses the config value.
    function run(bytes32 salt) external {
        _run(salt);
    }

    function _run(bytes32 saltArg) internal {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);

        // Resolve the salt (which lazily loads config via file-reading cheatcodes) BEFORE startBroadcast.
        // Constructing the StdConfig helper inside the broadcast region breaks forge's on-chain simulation.
        _overrideSalt(saltArg);
        bytes32 salt = _deploySalt();
        bytes memory initCode = type(WithdrawImplementation).creationCode;

        console.log("Deploying V5 TEST WithdrawImplementation via CREATE2...");
        console.log("Chain ID:  ", block.chainid);
        console.log("Salt:      ", vm.toString(salt));
        console.log("Predicted: ", _predictCreate2(salt, initCode));

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(salt, initCode);
        vm.stopBroadcast();

        // No constructor args, so this address is identical on every chain under the same salt.
        console.log("V5 test WithdrawImplementation deployed to:", deployed);
    }
}
