// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { V5TestBeaconConfig } from "./V5TestBeaconConfig.sol";
import { CounterfactualBeacon } from "../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { CounterfactualBeaconBootstrap } from "../../../contracts/periphery/counterfactual/CounterfactualBeaconBootstrap.sol";
import { CounterfactualDepositFactory } from "../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";

// Deploys the V5 TEST beacon stack under this folder's own CREATE2 salt, so it is a SEPARATE deployment from
// the production beacon on the same chain and nothing production is touched. Mechanically identical to
// DeployCounterfactualBeacon (same contracts, same idempotency, same self-healing), with two differences: the
// salt comes from v5-test-beacons/config.toml (or the CLI), and the beacon-bound `CounterfactualDepositFactory`
// is deployed here rather than by a separate script.
//
//   1. CounterfactualBeaconBootstrap via CREATE2 (no constructor args). Skipped when already deployed.
//   2. ERC1967Proxy via CREATE2 over the bootstrap, init calldata = bootstrap.initialize(deployer). The
//      deployer (chain-invariant, from MNEMONIC) is the bootstrap owner => identical init code => identical
//      proxy address on every chain. Skipped when already deployed.
//   3. `upgradeToAndCall(latestImpl, "")` ONLY when the proxy is still on the bootstrap (a fresh deploy),
//      pointing it at the impl from DeployV5TestBeaconImpl's broadcast for this chain. A proxy already on a
//      real impl keeps it — re-pointing a live beacon is an upgrade, performed out of band by the owner.
//   4. The dispatcher `new CounterfactualDeposit(ICounterfactualBeacon(proxy))` via CREATE2.
//   5. `setImplementation(dispatcher)` so every counterfactual BeaconProxy resolves the dispatcher.
//   6. `CounterfactualDepositFactory` via CREATE2, bound to the proxy.
//   7. Optionally `transferOwnership(ownerAndDirectWithdrawer)` (Ownable2Step; accepted out of band).
//
// WHY 4 AND 6 ARE REDEPLOYED RATHER THAN REUSED. `CounterfactualDeposit.BEACON` and
// `CounterfactualDepositFactory.BEACON` are immutables, and `setImplementation` rejects any target whose
// `BEACON()` does not point back at this beacon (`WrongBeacon`) — so the production dispatcher and factory
// cannot serve a beacon at a different proxy address. The LEAF implementations
// (`CounterfactualDepositSpokePool`, `…CCTP`, `…OFT`, `…VanillaCCTP`) hold no beacon immutable: they read
// config from the proxy's ERC-1967 beacon slot at runtime, so the EXISTING deployments are reused as-is and a
// route leaf simply names them. Nothing to redeploy there.
//
// How to run:
// 1. Deploy the impl first: DeployV5TestBeaconImpl.s.sol (with --broadcast; this script reads its broadcast).
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. FOUNDRY_PROFILE=counterfactual forge script \
//      script/counterfactual/v5-test-beacons/DeployV5TestBeacon.s.sol:DeployV5TestBeacon \
//      --sig "run()" --rpc-url base -vvvv
//    (there are four `run` overloads, so an explicit --sig is REQUIRED or forge aborts with
//     "Multiple functions with the same name run")
// 4. Deploy: append --broadcast --slow --verify
//
// Overloads: `run()`, `run(bool transferOwnership)`, `run(bytes32 salt)`, `run(bytes32 salt, bool transfer)`.
// Salt: `[0.bytes32] deploySalt` in this folder's config.toml, or pass a non-zero one for a one-off:
//      --sig "run(bytes32)" 0x…      /  --sig "run(bytes32,bool)" 0x… true
// Changing the salt mints a NEW proxy, dispatcher and factory — a fresh test beacon, not an upgrade. Anything
// bound to the old proxy (V5 routes, the destination executor) must be re-pointed.
contract DeployV5TestBeacon is V5TestBeaconConfig {
    string constant IMPL_SCRIPT = "DeployV5TestBeaconImpl.s.sol";

    /// @notice Deploys the test beacon stack with the config salt, keeping the deployer as owner.
    function run() external {
        _run(bytes32(0), false);
    }

    /// @param transferOwnership If true, transfer beacon ownership to config.toml `ownerAndDirectWithdrawer`
    ///        (Ownable2Step — the new owner accepts out of band).
    function run(bool transferOwnership) external {
        _run(bytes32(0), transferOwnership);
    }

    /// @param salt Non-zero to override `[0.bytes32] deploySalt`; `bytes32(0)` uses the config value.
    function run(bytes32 salt) external {
        _run(salt, false);
    }

    /// @param salt Non-zero to override `[0.bytes32] deploySalt`; `bytes32(0)` uses the config value.
    /// @param transferOwnership If true, transfer beacon ownership to config.toml `ownerAndDirectWithdrawer`
    ///        (Ownable2Step — the new owner accepts out of band).
    function run(bytes32 salt, bool transferOwnership) external {
        _run(salt, transferOwnership);
    }

    function _run(bytes32 saltArg, bool doTransferOwnership) internal {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Must precede every prediction below — it is what all four CREATE2 addresses hang off.
        _overrideSalt(saltArg);

        // Most recent test impl, from DeployV5TestBeaconImpl's broadcast for this chain. Resolved (not
        // required) here: only a FRESH proxy needs it, so a no-op / recovery / transfer-only re-run must not
        // demand a freshly recorded impl broadcast. The require lives in the fresh-deploy branch (step 3).
        address beaconImpl = getLatestBroadcastDeployment(IMPL_SCRIPT, "CounterfactualBeacon");

        bytes32 salt = _deploySalt();
        bytes memory proxyInitCode = _beaconProxyInitCode(deployer);
        address proxy = _predictCreate2(salt, proxyInitCode);
        address dispatcher = _predictDispatcher(proxy);
        bytes memory factoryInitCode = abi.encodePacked(
            type(CounterfactualDepositFactory).creationCode,
            abi.encode(proxy)
        );

        console.log("============================================");
        console.log("V5 TEST Counterfactual Beacon stack");
        console.log("============================================");
        console.log("Chain ID:            ", block.chainid);
        console.log("Deployer:            ", deployer);
        console.log("Salt:                ", vm.toString(salt));
        console.log("Predicted proxy:     ", proxy);
        console.log("Predicted dispatcher:", dispatcher);
        console.log("Predicted factory:   ", _predictCreate2(salt, factoryInitCode));

        vm.startBroadcast(deployerPrivateKey);

        // 1. Bootstrap (chain-identical init code; skipped when already deployed).
        address bootstrap = _deployCreate2(salt, type(CounterfactualBeaconBootstrap).creationCode);
        console.log("Bootstrap:           ", bootstrap);

        // 2. Beacon proxy over the bootstrap (chain-identical init code => same address everywhere).
        address deployedProxy = _deployCreate2(salt, proxyInitCode);
        require(deployedProxy == proxy, "proxy address mismatch");
        console.log("Beacon proxy:        ", deployedProxy);

        CounterfactualBeacon beacon = CounterfactualBeacon(deployedProxy);

        // The proxy's impl slot says where we are:
        //   - still on the bootstrap          => fresh proxy; point it at the chain-specific impl (step 3).
        //   - on a real impl, dispatcher set  => fully deployed; skip to steps 6-7 (never re-point a live
        //     beacon — that's an upgrade, done out of band by the owner).
        //   - on a real impl, dispatcher unset => an earlier run died before wiring the dispatcher; DON'T
        //     re-point the impl, but DO finish the wiring.
        address currentImpl = address(uint160(uint256(vm.load(deployedProxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        bool onBootstrap = currentImpl == bootstrap;
        if (!onBootstrap && beacon.implementation() == dispatcher) {
            console.log("Beacon already deployed and wired; impl slot:", currentImpl);
            console.log("No beacon changes (upgrades are performed separately by the owner).");
        } else {
            // 3. Point a FRESH proxy from the bootstrap at the chain-specific impl. The bootstrap already
            //    consumed the initializer slot, so pass empty calldata (no re-init). onlyOwner — a fresh
            //    proxy's bootstrap.initialize set the deployer as owner.
            if (onBootstrap) {
                if (beaconImpl == address(0)) {
                    console.log("ERROR: no V5 test beacon impl broadcast for chain %d.", block.chainid);
                    console.log("Run DeployV5TestBeaconImpl with --broadcast first.");
                }
                require(beaconImpl != address(0), "no impl broadcast for this chain: run DeployV5TestBeaconImpl");
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

            // 4. Dispatcher (CounterfactualDeposit), bound to this test proxy.
            address deployedDispatcher = _deployCreate2(salt, _dispatcherInitCode(deployedProxy));
            require(deployedDispatcher == dispatcher, "dispatcher address mismatch");
            console.log("Dispatcher:          ", deployedDispatcher);

            // 5. Point the beacon at the dispatcher so every counterfactual proxy runs it (onlyOwner).
            //    Idempotent, so a recovery run that only needs this step finishes it.
            if (beacon.implementation() != deployedDispatcher) {
                require(beacon.owner() == deployer, "deployer is not beacon owner: owner must setImplementation");
                beacon.setImplementation(deployedDispatcher);
            } else {
                console.log("Dispatcher already wired");
            }
        }

        // 6. Factory, bound to this test proxy (every clone it deploys resolves this beacon). Deployed here
        //    rather than by a separate script because the binding is immutable: a test beacon needs its own.
        console.log("Factory:             ", _deployCreate2(salt, factoryInitCode));

        // 7. Optionally hand the beacon over to the multisig (Ownable2Step accept out of band).
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
        console.log("V5 test beacon stack deployed.");
        console.log("Existing leaf impls (SpokePool/CCTP/OFT/VanillaCCTP) are reused: they hold no beacon.");
        console.log("============================================");
    }
}
