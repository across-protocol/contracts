// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { StdConstants } from "forge-std/StdConstants.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import {
    CounterfactualBeacon,
    CounterfactualChainConfig
} from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { CounterfactualBeaconBootstrap } from "../../contracts/periphery/counterfactual/CounterfactualBeaconBootstrap.sol";

/// @dev Throwaway harness deployed on each fork so `_buildChainConfig`'s requires (missing fee cap, declared
///      support mismatch, ...) can be try/caught per chain — one misconfigured chain then skips with a reason
///      instead of aborting the whole batch. Mirrors the resolver in CheckCounterfactualBeaconImpls.
contract BeaconChainConfigResolver is CounterfactualConfig {
    function build() external returns (CounterfactualChainConfig memory) {
        return _buildChainConfig();
    }
}

// Deploys the counterfactual BEACON STACK to a list of chains in one run: per chain the chain-specific
// implementation, the chain-identical bootstrap and proxy, and the dispatcher the proxy resolves.
//
// This is the multi-chain replacement for running DeployCounterfactualBeaconImpl + DeployCounterfactualBeacon
// by hand per chain (and for scripts/deployCounterfactualBeaconImpls.sh, deleted in 29a20f69).
//
// Per chain, all idempotent — an already-deployed piece is logged and skipped, so a re-run finishes an
// interrupted batch:
//   1. CounterfactualBeaconBootstrap via CREATE2 (no ctor args => same address everywhere).
//   2. ERC1967Proxy via CREATE2 over the bootstrap, init calldata = bootstrap.initialize(deployer). Deployer
//      is chain-invariant, so the proxy address is identical on every chain — the anchor routes commit.
//   3. The chain-specific CounterfactualBeacon implementation (plain CREATE; it sits behind the proxy) —
//      deployed ONLY when the proxy is still on the bootstrap and therefore actually needs one.
//   4. `upgradeToAndCall(impl, "")` to move the fresh proxy off the bootstrap. Empty calldata: the bootstrap
//      already consumed the initializer slot.
//   5. CounterfactualDeposit (the dispatcher) via CREATE2, bound to the proxy.
//   6. `setImplementation(dispatcher)` so every counterfactual BeaconProxy resolves it.
//
// The impl is built and used in the SAME run, unlike the two-script flow where DeployCounterfactualBeacon
// reads whatever DeployCounterfactualBeaconImpl last broadcast. That handoff is the one way to point a fresh
// proxy at a stale implementation, and it is not possible here.
//
// NOT deployed (deliberately): CounterfactualDepositFactory, WithdrawImplementation, AdminWithdrawManager and
// the route leaves. Only the dispatcher and the factory embed the beacon; everything else is beacon-agnostic
// and its existing deployment serves any beacon. Ownership is left with the DEPLOYER — no transfer.
//
// Chains are skipped, with a logged reason and no effect on the rest of the batch, when: the chain is Tron
// (forge cannot broadcast there — use yarn tron-deploy-counterfactual-beacon-impl), `NODE_URL_<chainId>` is
// unset or unreachable, the CREATE2 factory is absent, or the chain's config does not resolve.
//
// How to run:
// 1. `source .env` with MNEMONIC, the NODE_URL_<chainId> for each target chain, and ETHERSCAN_API_KEY.
// 2. FOUNDRY_PROFILE=counterfactual forge script \
//      script/counterfactual/DeployCounterfactualBeaconStack.s.sol:DeployCounterfactualBeaconStack \
//      --sig "run(uint256[])" "[8453,42161]" --rpc-url $NODE_URL_1 --gas-limit 100000000000 -vvvv
//    (--rpc-url is required even though the script forks per chain: the inherited DeploymentUtils reads
//     this chain's constants when the script contract is constructed, and chain 31337 has no entry.
//     --gas-limit: the whole batch runs in one EVM frame, and per-chain JSON/TOML cheatcode work outgrows
//     the default limit once you pass a handful of chains.)
// 3. Deploy: append --broadcast --slow --verify --etherscan-api-key $ETHERSCAN_API_KEY
//    (--slow: each chain is a multi-tx sequence; without it later txs can be dropped against an RPC whose
//     nonce view lags, leaving the proxy stranded on the bootstrap.)
contract DeployCounterfactualBeaconStack is CounterfactualConfig {
    uint256 constant TRON_CHAIN_ID = 728126428;

    /// @dev One resolver for the whole run, persistent across forks. Constructing it re-reads the multi-MB
    ///      constants.json and the config TOML, so building one per chain exhausts the single EVM frame this
    ///      script runs in — the batch then fails as bogus "config did not resolve" skips followed by a bare
    ///      revert. `deployCode` (not `new`) keeps its creation code out of this contract's bytecode.
    BeaconChainConfigResolver internal resolver;

    uint256 internal deployed;
    uint256 internal skipped;

    /// @param chainIds Chains to deploy to, e.g. `[8453,42161]`.
    function run(uint256[] calldata chainIds) external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("============================================");
        console.log("Counterfactual beacon stack - %d chain(s)", chainIds.length);
        console.log("Deployer / beacon owner: %s", deployer);
        console.log("============================================");

        resolver = BeaconChainConfigResolver(
            deployCode("DeployCounterfactualBeaconStack.s.sol:BeaconChainConfigResolver")
        );
        vm.makePersistent(address(resolver));

        for (uint256 i = 0; i < chainIds.length; i++) {
            _runOn(chainIds[i], deployerPrivateKey, deployer);
        }

        console.log("");
        console.log("============================================");
        console.log("Done: %d chain(s) deployed, %d skipped.", deployed, skipped);
        console.log("Ownership left with the deployer; no transfer performed.");
        console.log("============================================");
    }

    function _runOn(uint256 chainId, uint256 deployerPrivateKey, address deployer) internal {
        console.log("");
        console.log("=== Chain %d ===", chainId);
        if (chainId == TRON_CHAIN_ID) return _skip("Tron - forge cannot broadcast; use the TypeScript path");

        try vm.createFork(vm.envString(string.concat("NODE_URL_", vm.toString(chainId)))) returns (uint256 forkId) {
            vm.selectFork(forkId);
        } catch {
            return _skip("NODE_URL unset or RPC unreachable");
        }
        if (block.chainid != chainId) return _skip("RPC reports a different chain id");
        if (StdConstants.CREATE2_FACTORY.code.length == 0) return _skip("CREATE2 factory not deployed here");

        // Resolve the config through a fresh harness so this chain's requires can be caught. File-reading
        // cheatcodes must also run BEFORE startBroadcast — building StdConfig inside a broadcast region
        // breaks forge's on-chain simulation.
        CounterfactualChainConfig memory chainConfig;
        try resolver.build() returns (CounterfactualChainConfig memory c) {
            chainConfig = c;
        } catch Error(string memory reason) {
            return _skip(string.concat("config: ", reason));
        } catch {
            return _skip("config did not resolve (see the chain's config.toml entry)");
        }

        bytes32 salt = _deploySalt();
        bytes memory proxyInitCode = _beaconProxyInitCode(deployer);
        address proxy = _predictCreate2(salt, proxyInitCode);
        address dispatcher = _predictDispatcher(proxy);
        console.log("  Predicted proxy:      %s", proxy);
        console.log("  Predicted dispatcher: %s", dispatcher);

        vm.startBroadcast(deployerPrivateKey);

        address bootstrap = _deployCreate2(salt, type(CounterfactualBeaconBootstrap).creationCode);
        require(_deployCreate2(salt, proxyInitCode) == proxy, "proxy address mismatch");
        CounterfactualBeacon beacon = CounterfactualBeacon(proxy);

        // The impl slot says where this chain is: still on the bootstrap means a fresh proxy that needs an
        // implementation. A proxy already on a real impl keeps it — re-pointing a live beacon is an upgrade,
        // performed out of band by the owner, never silently as part of a deploy.
        address currentImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        if (currentImpl == bootstrap) {
            require(beacon.owner() == deployer, "deployer is not beacon owner");
            address impl = address(new CounterfactualBeacon(chainConfig));
            CounterfactualBeaconBootstrap(payable(proxy)).upgradeToAndCall(impl, "");
            console.log("  Impl deployed:        %s", impl);
        } else {
            console.log("  Impl already set:     %s (left as-is; upgrades are done out of band)", currentImpl);
        }

        require(_deployCreate2(salt, _dispatcherInitCode(proxy)) == dispatcher, "dispatcher address mismatch");
        if (beacon.implementation() != dispatcher) {
            require(beacon.owner() == deployer, "deployer is not beacon owner: owner must setImplementation");
            beacon.setImplementation(dispatcher);
            console.log("  Dispatcher wired.");
        } else {
            console.log("  Dispatcher already wired.");
        }

        vm.stopBroadcast();
        deployed++;
    }

    function _skip(string memory reason) private {
        console.log("  Skipping: %s", reason);
        skipped++;
    }
}
