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
// Deploy-only: this script stands up a NEW beacon but never upgrades a live one. A fresh proxy still sits on
// the bootstrap (its ERC1967 impl slot == the bootstrap); once it has been pointed at a real impl the beacon
// is considered deployed and this script makes no further changes. Re-pointing a live beacon to a newer impl
// or dispatcher is an upgrade, performed out of band by the beacon owner — not here.
//   1. CounterfactualBeaconBootstrap via CREATE2 (no constructor args => same address everywhere). Skipped
//      when already deployed.
//   2. ERC1967Proxy via CREATE2 over the bootstrap, init calldata = bootstrap.initialize(deployer). The
//      deployer (chain-invariant, from MNEMONIC) is the bootstrap owner => identical init code => identical
//      proxy address. (Do NOT put the per-chain multisig in the init calldata — that breaks address parity.)
//      Skipped when already deployed.
//   3. `upgradeToAndCall(latestImpl, "")` ONLY when the proxy is still on the bootstrap (a fresh deploy),
//      pointing it at the chain-specific impl. A proxy already on a real impl is left untouched (no upgrade).
//      The bootstrap already consumed the initializer slot, so pass empty calldata (no re-init).
//   4. The dispatcher `new CounterfactualDeposit(ICounterfactualBeacon(proxy))` via CREATE2 (proxy is
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
        // Failures are console.log'd before the require: the default profile strips revert strings.
        address beaconImpl = getLatestBroadcastDeployment(IMPL_SCRIPT, "CounterfactualBeacon");
        if (beaconImpl == address(0)) {
            console.log("ERROR: no CounterfactualBeacon impl broadcast for chain %d.", block.chainid);
            console.log("Run DeployCounterfactualBeaconImpl with --broadcast first.");
        }
        require(beaconImpl != address(0), "no impl broadcast for this chain: run DeployCounterfactualBeaconImpl first");
        if (beaconImpl.code.length == 0) {
            console.log("ERROR: latest impl broadcast (%s) has no on-chain code.", beaconImpl);
            console.log("Re-run DeployCounterfactualBeaconImpl with --broadcast.");
        }
        require(beaconImpl.code.length > 0, "latest impl broadcast has no on-chain code: redeploy it with --broadcast");

        bytes32 salt = _deploySalt();
        bytes memory proxyInitCode = _beaconProxyInitCode(deployer);
        address proxy = _predictCreate2(salt, proxyInitCode);
        address dispatcher = _predictDispatcher(proxy);

        console.log("============================================");
        console.log("Counterfactual Beacon proxy deployment");
        console.log("============================================");
        console.log("Chain ID:           ", block.chainid);
        console.log("Deployer:           ", deployer);
        console.log("Latest beacon impl: ", beaconImpl);
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

        // Deploy-only guard: a fresh proxy still points at the bootstrap. Once it has been pointed at a real
        // impl the beacon is deployed, and this script never upgrades a live beacon — bail without changes.
        // (Re-pointing to a newer impl/dispatcher is an upgrade, performed out of band by the beacon owner.)
        address currentImpl = address(uint160(uint256(vm.load(deployedProxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        if (currentImpl != bootstrap) {
            vm.stopBroadcast();
            console.log("Beacon already deployed; impl slot:", currentImpl);
            console.log("Deploy-only script makes no changes. Upgrades are performed separately by the owner.");
            console.log("============================================");
            return;
        }

        // 3. Point the fresh proxy from the bootstrap at the chain-specific impl. The bootstrap already
        //    consumed the initializer slot, so pass empty calldata (no re-init); chain config comes from the
        //    impl's immutables, and implementation/upgradeRoot are set via owner setters. onlyOwner — a fresh
        //    proxy's bootstrap.initialize set the deployer as owner, so this holds.
        require(beacon.owner() == deployer, "deployer is not beacon owner");
        CounterfactualBeaconBootstrap(payable(deployedProxy)).upgradeToAndCall(beaconImpl, "");
        console.log("Pointed proxy at impl:", beaconImpl);

        // 4. Dispatcher (CounterfactualDeposit), bound to the chain-invariant proxy => same address; skipped
        //    when already deployed.
        address deployedDispatcher = _deployCreate2(salt, _dispatcherInitCode(deployedProxy));
        require(deployedDispatcher == dispatcher, "dispatcher address mismatch");
        console.log("Dispatcher:         ", deployedDispatcher);

        // 5. Point the beacon at the dispatcher so every counterfactual proxy runs it (onlyOwner, like 3).
        beacon.setImplementation(deployedDispatcher);

        // 6. Optionally hand the beacon over to the per-chain multisig (Ownable2Step accept out of band).
        if (doTransferOwnership) {
            address newOwner = config.get("ownerAndDirectWithdrawer").toAddress();
            require(newOwner != address(0), "config: ownerAndDirectWithdrawer is zero or missing");
            if (beacon.owner() != newOwner) {
                console.log("Transferring beacon ownership to:", newOwner);
                beacon.transferOwnership(newOwner);
            }
        }

        vm.stopBroadcast();

        console.log("============================================");
        console.log("Beacon stack deployed.");
        console.log("============================================");
    }
}
