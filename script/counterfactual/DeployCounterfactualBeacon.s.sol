// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualBeacon } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { CounterfactualBeaconBootstrap } from "../../contracts/periphery/counterfactual/CounterfactualBeaconBootstrap.sol";

// Deploys the counterfactual beacon **proxy** stack so the proxy lands at the SAME address on every chain
// (every counterfactual proxy and the factory embed it). The chain-specific CounterfactualBeacon
// implementation is deployed separately by DeployCounterfactualBeaconImpl.s.sol; this script reads that
// script's broadcast run-latest.json for this chain and points a FRESH proxy at the most recent impl.
//
// Deploy-only: this script stands up a NEW beacon (and finishes an interrupted deploy) but never upgrades a
// live one. A fresh proxy still sits on the bootstrap (its ERC1967 impl slot == the bootstrap). Once the
// proxy runs a real impl AND is wired to the dispatcher the beacon is fully deployed and this script deploys
// nothing further (though `run(true)` still performs the optional ownership transfer below). Re-pointing a
// live beacon to a newer impl is an upgrade, performed out of band by the owner — not here; but if an earlier
// run upgraded the proxy yet died before wiring the dispatcher, a re-run completes that wiring (without
// re-pointing the impl). The impl broadcast is only required for the fresh-proxy path.
//   1. CounterfactualBeaconBootstrap via CREATE2 (no constructor args => same address everywhere). Skipped
//      when already deployed.
//   2. ERC1967Proxy via CREATE2 over the bootstrap, init calldata = bootstrap.initialize(deployer). The
//      deployer (chain-invariant, from MNEMONIC) is the bootstrap owner => identical init code => identical
//      proxy address. (Do NOT put the per-chain multisig in the init calldata — that breaks address parity.)
//      Skipped when already deployed.
//   3. `upgradeToAndCall(latestImpl, "")` ONLY when the proxy is still on the bootstrap (a fresh deploy),
//      pointing it at the chain-specific impl. A proxy already on a real impl keeps that impl (no upgrade);
//      the dispatcher wiring in steps 4-5 still runs so an interrupted deploy is completed.
//      The bootstrap already consumed the initializer slot, so pass empty calldata (no re-init).
//   4. The dispatcher `new CounterfactualDeposit(ICounterfactualBeaconBase(proxy))` via CREATE2 (proxy is
//      chain-invariant => dispatcher is same address everywhere). Skipped when already deployed.
//   5. `setImplementation(dispatcher)` on the proxy so every counterfactual proxy resolves the dispatcher.
//   6. Optionally `transferOwnership(ownerAndDirectWithdrawer)` (Ownable2Step; new owner accepts out of band).
//
// How to run:
// 1. Deploy the impl: DeployCounterfactualBeaconImpl.s.sol (after a config change, redeploy the impl and
//    upgrade the beacon separately — this script will NOT move a live beacon to the new impl)
// 2. Edit script/counterfactual/config.toml with signer + ownerAndDirectWithdrawer per chain
// 3. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 4. forge script script/counterfactual/DeployCounterfactualBeacon.s.sol:DeployCounterfactualBeacon \
//      --rpc-url $NODE_URL -vvvv
// 5. Deploy: append --broadcast --verify (add --sig "run(bool)" true to also hand the beacon to the multisig)
contract DeployCounterfactualBeacon is CounterfactualConfig {
    string constant IMPL_SCRIPT = "DeployCounterfactualBeaconImpl.s.sol";

    /// @notice Zero-arg entry point: deploys the beacon stack, keeping the deployer as owner.
    function run() external {
        _run(false);
    }

    /// @param transferOwnership If true, transfer beacon ownership to config.toml `ownerAndDirectWithdrawer`
    ///        (Ownable2Step — the new owner accepts out of band).
    function run(bool transferOwnership) external {
        _run(transferOwnership);
    }

    function _run(bool doTransferOwnership) internal {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Most recent chain-specific impl, from DeployCounterfactualBeaconImpl's broadcast for this chain.
        // Resolved (not required) here: only a FRESH proxy needs it, so a no-op / recovery / transfer-only
        // re-run must not demand a freshly recorded impl broadcast. getLatestBroadcastDeployment returns 0
        // when none exists; the require lives in the fresh-deploy branch below (step 3).
        address beaconImpl = getLatestBroadcastDeployment(IMPL_SCRIPT, "CounterfactualBeacon");

        bytes32 salt = _deploySalt();
        bytes memory proxyInitCode = _beaconProxyInitCode(deployer);
        address proxy = _predictCreate2(salt, proxyInitCode);
        address dispatcher = _predictDispatcher(proxy);

        console.log("============================================");
        console.log("Counterfactual Beacon proxy deployment");
        console.log("============================================");
        console.log("Chain ID:           ", block.chainid);
        console.log("Deployer:           ", deployer);
        console.log("Predicted proxy:    ", proxy);
        console.log("Predicted dispatcher:", dispatcher);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Bootstrap (chain-identical init code; skipped when already deployed).
        address bootstrap = _deployCreate2(salt, type(CounterfactualBeaconBootstrap).creationCode);
        console.log("Bootstrap:          ", bootstrap);

        // 2. Beacon proxy over the bootstrap (chain-identical init code => same address; skipped when
        //    already deployed).
        address deployedProxy = _deployCreate2(salt, proxyInitCode);
        require(deployedProxy == proxy, "proxy address mismatch");
        console.log("Beacon proxy:       ", deployedProxy);

        CounterfactualBeacon beacon = CounterfactualBeacon(deployedProxy);

        // Deploy-only, but still finishes an interrupted deploy. The proxy's impl slot says where we are:
        //   - still on the bootstrap          => fresh proxy; point it at the chain-specific impl (step 3).
        //   - on a real impl, dispatcher set   => fully deployed; skip the deploy/wiring steps (never re-point
        //     a live beacon — that's an upgrade, done out of band by the owner).
        //   - on a real impl, dispatcher unset => an earlier run upgraded the proxy but died before wiring the
        //     dispatcher; DON'T re-point the impl, but DO finish the dispatcher wiring (steps 4-5).
        // Step 6 (optional ownership transfer) runs in EVERY path, so `run(true)` still hands an
        // already-deployed beacon to the multisig.
        address currentImpl = address(uint160(uint256(vm.load(deployedProxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        bool onBootstrap = currentImpl == bootstrap;
        if (!onBootstrap && beacon.implementation() == dispatcher) {
            console.log("Beacon already deployed and wired; impl slot:", currentImpl);
            console.log("No deployment changes (upgrades are performed separately by the owner).");
        } else {
            // 3. Point a FRESH proxy from the bootstrap at the chain-specific impl. Skipped when the proxy
            //    already runs a real impl: re-pointing a live beacon to a different impl is an upgrade, not
            //    done here. Only a fresh deploy needs the impl, so require it HERE (not up front, where it
            //    would block no-op/recovery/transfer-only re-runs). The bootstrap already consumed the
            //    initializer slot, so pass empty calldata (no re-init). onlyOwner — a fresh proxy's
            //    bootstrap.initialize set the deployer as owner.
            if (onBootstrap) {
                if (beaconImpl == address(0)) {
                    console.log("ERROR: no CounterfactualBeacon impl broadcast for chain %d.", block.chainid);
                    console.log("Run DeployCounterfactualBeaconImpl with --broadcast first.");
                }
                require(
                    beaconImpl != address(0),
                    "no impl broadcast for this chain: run DeployCounterfactualBeaconImpl first"
                );
                require(
                    beaconImpl.code.length > 0,
                    "latest impl broadcast has no on-chain code: redeploy it with --broadcast"
                );
                require(beacon.owner() == deployer, "deployer is not beacon owner");
                CounterfactualBeaconBootstrap(payable(deployedProxy)).upgradeToAndCall(beaconImpl, "");
                console.log("Pointed proxy at impl:", beaconImpl);
            } else {
                console.log("Proxy already on a real impl; leaving it as-is (no upgrade):", currentImpl);
            }

            // 4. Dispatcher (CounterfactualDeposit), bound to the chain-invariant proxy => same address;
            //    skipped when already deployed.
            address deployedDispatcher = _deployCreate2(salt, _dispatcherInitCode(deployedProxy));
            require(deployedDispatcher == dispatcher, "dispatcher address mismatch");
            console.log("Dispatcher:         ", deployedDispatcher);

            // 5. Point the beacon at the dispatcher so every counterfactual proxy runs it (onlyOwner).
            //    Idempotent: skipped when already wired, so a recovery run that only needs this step finishes it.
            if (beacon.implementation() != deployedDispatcher) {
                require(beacon.owner() == deployer, "deployer is not beacon owner: owner must setImplementation");
                beacon.setImplementation(deployedDispatcher);
            } else {
                console.log("Dispatcher already wired");
            }
        }

        // 6. Optionally hand the beacon over to the per-chain multisig (Ownable2Step accept out of band).
        if (doTransferOwnership) {
            address newOwner = config.get("ownerAndDirectWithdrawer").toAddress();
            require(newOwner != address(0), "config: ownerAndDirectWithdrawer is zero or missing");
            if (beacon.owner() != newOwner) {
                console.log("Transferring beacon ownership to:", newOwner);
                beacon.transferOwnership(newOwner);
            } else {
                console.log("Beacon ownership already at target:", newOwner);
            }
        }

        vm.stopBroadcast();

        console.log("============================================");
        console.log("Beacon stack deployed.");
        console.log("============================================");
    }
}
