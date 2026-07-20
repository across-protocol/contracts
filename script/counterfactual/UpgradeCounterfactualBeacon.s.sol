// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualBeacon } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { CounterfactualBeaconBootstrap } from "../../contracts/periphery/counterfactual/CounterfactualBeaconBootstrap.sol";

// Upgrades the LIVE CounterfactualBeacon proxy to the most recent chain-specific implementation — the last
// `CounterfactualBeacon` recorded in broadcast/DeployCounterfactualBeaconImpl.s.sol/<chainId>/run-latest.json —
// via `upgradeToAndCall(newImpl, "")`. Only works while the deployer (MNEMONIC index 0) is still the beacon
// owner; once ownership has moved to a multisig the upgrade must go through it instead (use the calldata
// printed by CheckCounterfactualBeaconImpls.s.sol).
//
// Every terminal outcome prints a single machine-greppable line `Upgrade status: <STATUS>`:
//   UPGRADED        proxy re-pointed at the latest impl (or would be, on a dry-run)
//   ALREADY-LATEST  proxy already runs the latest broadcast impl; nothing to do
//   NOT-OWNER       beacon owner is not the deployer (multisig-owned chain) — no tx attempted
//   ON-BOOTSTRAP    proxy still on the bootstrap (fresh deploy) — run DeployCounterfactualBeacon instead
//   NO-PROXY        no live beacon proxy on this chain — run DeployCounterfactualBeacon first
//   NO-IMPL         no (or code-less) impl broadcast — run DeployCounterfactualBeaconImpl --broadcast first
// Non-UPGRADED/ALREADY-LATEST outcomes return without reverting so a multi-chain wrapper can classify them
// (see scripts/upgradeCounterfactualBeacons.sh).
//
// How to run:
// 1. Deploy the new impl: DeployCounterfactualBeaconImpl.s.sol --broadcast
// 2. Verify it: CheckCounterfactualBeaconImpls.s.sol (getters vs config sources, upgrade diff)
// 3. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 4. forge script script/counterfactual/UpgradeCounterfactualBeacon.s.sol:UpgradeCounterfactualBeacon \
//      --rpc-url $NODE_URL -vvv
// 5. Upgrade: append --broadcast
//
// To run across many chains in one shot with a per-chain OK/SKIP/FAIL summary, use
// scripts/upgradeCounterfactualBeacons.sh.
contract UpgradeCounterfactualBeacon is CounterfactualConfig {
    string constant IMPL_SCRIPT = "DeployCounterfactualBeaconImpl.s.sol";

    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("============================================");
        console.log("CounterfactualBeacon proxy upgrade");
        console.log("============================================");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);

        // Live proxy: deployed-addresses.json first, CREATE2 prediction as fallback for chains deployed
        // since the last address extraction (the proxy address is chain-invariant by construction).
        address proxy = getDeployedAddress("CounterfactualBeacon", block.chainid, false);
        if (proxy == address(0)) proxy = _predictBeaconProxy(deployer);
        if (proxy.code.length == 0) {
            console.log("Upgrade status: NO-PROXY (no live beacon proxy; run DeployCounterfactualBeacon first)");
            return;
        }
        console.log("Beacon proxy:", proxy);

        address newImpl = getLatestBroadcastDeployment(IMPL_SCRIPT, "CounterfactualBeacon");
        if (newImpl == address(0)) {
            console.log("Upgrade status: NO-IMPL (no DeployCounterfactualBeaconImpl broadcast for this chain)");
            return;
        }
        if (newImpl.code.length == 0) {
            console.log("Latest broadcast impl has no code on-chain:", newImpl);
            console.log("Upgrade status: NO-IMPL (redeploy with DeployCounterfactualBeaconImpl --broadcast)");
            return;
        }

        address currentImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        console.log("Live impl:  ", currentImpl);
        console.log("Latest impl:", newImpl);
        if (currentImpl == newImpl) {
            console.log("Upgrade status: ALREADY-LATEST");
            return;
        }

        // A proxy still on the chain-invariant bootstrap is an unfinished FRESH deploy, not an upgrade:
        // DeployCounterfactualBeacon must finish it (impl + dispatcher wiring).
        if (currentImpl == _predictCreate2(_deploySalt(), type(CounterfactualBeaconBootstrap).creationCode)) {
            console.log("Upgrade status: ON-BOOTSTRAP (fresh proxy; run DeployCounterfactualBeacon to finish)");
            return;
        }

        CounterfactualBeacon beacon = CounterfactualBeacon(proxy);
        address owner = beacon.owner();
        if (owner != deployer) {
            console.log("Beacon owner:", owner);
            console.log("Upgrade status: NOT-OWNER (upgrade via the owner; see CheckCounterfactualBeaconImpls)");
            return;
        }

        // upgradeToAndCall validates the target's proxiableUUID (UUPS) before switching the impl slot.
        vm.startBroadcast(deployerPrivateKey);
        beacon.upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        console.log("Upgraded impl %s -> %s", currentImpl, newImpl);
        console.log("Upgrade status: UPGRADED");
    }
}
