// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { V5TestBeaconConfig } from "./V5TestBeaconConfig.sol";
import { AdminWithdrawManager } from "../../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// Deploys `AdminWithdrawManager` under the V5 TEST salt, with the DEPLOYER as both `owner` and
// `directWithdrawer` and the `signer` from this folder's config.toml. Same contract and mechanics as the
// production DeployAdminWithdrawManager, and it performs NO role transfer: unlike production — where the roles
// move to the `ownerAndDirectWithdrawer` multisig out of band — the deployer keeps them, so admin withdrawals
// can be exercised from the dev wallet without a multisig ceremony. That role difference, not the salt, is the
// real reason this is a separate deployment: the contract is beacon-agnostic, so the production one would
// otherwise serve fine.
//
// The three constructor args are all global (deployer, deployer, signer), so the CREATE2 address is identical
// on every chain under the same salt — but it differs from production's, since both the salt AND the roles
// differ (production's live instance has since transferred them, though the baked ctor args are what count).
//
// Note `signer` here is the same EIP-712 quote signer the beacon publishes; `AdminWithdrawManager` uses it for
// `signedWithdrawToUser`, independently of the beacon.
//
// How to run:
// 1. Edit script/counterfactual/v5-test-beacons/config.toml so `signer` is set for this chain.
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. FOUNDRY_PROFILE=counterfactual forge script \
//      script/counterfactual/v5-test-beacons/DeployV5TestAdminWithdrawManager.s.sol:DeployV5TestAdminWithdrawManager \
//      --sig "run()" --rpc-url base -vvvv
//    (two `run` overloads, so an explicit --sig is REQUIRED)
// 4. Deploy: append --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
contract DeployV5TestAdminWithdrawManager is V5TestBeaconConfig {
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
        address deployer = vm.addr(deployerPrivateKey);

        // Resolve config-derived values (signer, salt) BEFORE startBroadcast — they load config via
        // file-reading cheatcodes, and constructing the StdConfig helper inside the broadcast region breaks
        // forge's on-chain simulation.
        _overrideSalt(saltArg);
        address signer = _loadSigner();
        bytes32 salt = _deploySalt();

        // owner = directWithdrawer = deployer. Deliberate and deliberately NOT transferred afterwards.
        bytes memory initCode = abi.encodePacked(
            type(AdminWithdrawManager).creationCode,
            abi.encode(deployer, deployer, signer)
        );

        console.log("Deploying V5 TEST AdminWithdrawManager via CREATE2...");
        console.log("Chain ID:                     ", block.chainid);
        console.log("Salt:                         ", vm.toString(salt));
        console.log("Owner / directWithdrawer:     ", deployer);
        console.log("Signer:                       ", signer);
        console.log("Predicted:                    ", _predictCreate2(salt, initCode));

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(salt, initCode);
        vm.stopBroadcast();

        console.log("V5 test AdminWithdrawManager deployed to:", deployed);
        console.log("Roles stay with the deployer; no transferOwnership is performed.");
    }
}
