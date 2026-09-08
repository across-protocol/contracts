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
// per-chain address (plain CREATE) — it sits behind the address-stable beacon proxy. On a fresh chain
// DeployCounterfactualBeacon.s.sol reads this script's broadcast run-latest.json and points the newly
// deployed proxy at the most recent impl.
//
// Run this script first on a fresh chain, then run DeployCounterfactualBeacon to deploy the proxy pointed at
// this impl. After a config change the impl is immutable, so a change means a new impl AND a proxy upgrade —
// but DeployCounterfactualBeacon is deploy-only and will NOT move a live beacon. The owner must perform that
// upgrade out of band: `CounterfactualBeacon(proxy).upgradeToAndCall(newImpl, "")` — while the dev wallet is
// still the owner, UpgradeCounterfactualBeacon.s.sol (or scripts/upgradeCounterfactualBeacons.sh for many
// chains) does exactly that.
//
// How to run:
// 1. Edit script/counterfactual/config.toml with the signer, per-token max-execution-fee caps for
//    this chain (raw onchain amounts in the token's own decimals, e.g. 2000000 for 2 six-decimal USDC),
//    and the chain's `[N.bool]` declared-support flags. The flags are cross-checked against
//    constants.json + deployed-addresses.json and ANY mismatch (either direction, or a missing flag)
//    reverts the deployment — see the config.toml header and CounterfactualConfig._validateDeclaredSupport.
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script script/counterfactual/DeployCounterfactualBeaconImpl.s.sol:DeployCounterfactualBeaconImpl \
//      --rpc-url $NODE_URL -vvvv
// 4. Deploy: append --broadcast --verify
//
// To run across many chains (or all config.toml chains except Tron) in one shot with a per-chain
// PASS/FAIL log, use scripts/deployCounterfactualBeaconImpls.sh.
//
// After deploying, verify the impls (getters vs config sources, on-chain token/periphery identity,
// upgrade diff + multisig calldata) with CheckCounterfactualBeaconImpls.s.sol before asking the owner
// to upgrade.
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
