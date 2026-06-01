// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { RoutePolicyImmutableRoot } from "../../contracts/periphery/counterfactual/RoutePolicyImmutableRoot.sol";

// Deploys the genesis RoutePolicy: an implementation carrying the genesis root (bytes32(0)) plus an
// ERC1967Proxy that points at it and is initialized with the deployer EOA as owner. Both are
// deployed via CREATE2 through the deterministic-deployment proxy.
//
// CROSS-CHAIN INVARIANT: the proxy address IS `cloneArgs.routePolicyAddress`, which feeds the clone
// argsHash. For clones to land at the same address on every chain, this proxy MUST land at the same
// address on every chain. That holds iff:
//   1. The implementation is constructed with the same root everywhere → use the genesis root
//      (bytes32(0)). The real per-chain root is applied LATER via `RotateRoutePolicyRoot`, an
//      `upgradeToAndCall` that does NOT change the proxy address.
//   2. The proxy init data is identical everywhere → owner is the deployer EOA (global, derived from
//      the same mnemonic), not the chain-local multisig. Ownership is transferred to the chain-local
//      multisig as a post-deploy step (handled by DeployAllCounterfactual when transferRoles=true,
//      or manually) — a state change that does not affect the address.
//
// Do NOT bake a real (non-zero) root into the genesis implementation: a per-chain root would give a
// per-chain implementation address and therefore a per-chain proxy address, breaking clone-address
// consistency.
//
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployRoutePolicy.s.sol:DeployRoutePolicy --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployRoutePolicy is CounterfactualConfig {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying RoutePolicy (impl + proxy) via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("Genesis owner (deployer EOA):", deployer);
        console.log("Predicted impl: ", _predictRoutePolicyImpl());
        console.log("Predicted proxy:", _predictRoutePolicyProxy(deployer));

        vm.startBroadcast(deployerPrivateKey);

        bytes32 salt = _deploySalt();

        // 1. Implementation carrying the genesis root (identical bytecode across chains).
        address impl = _deployCreate2(salt, _routePolicyImplInitCode());

        // 2. ERC1967Proxy pointing at the impl, initialized with the deployer EOA as owner.
        address proxy = _deployCreate2(salt, _routePolicyProxyInitCode(impl, deployer));

        vm.stopBroadcast();

        console.log("RoutePolicy impl deployed to: ", impl);
        console.log("RoutePolicy proxy deployed to:", proxy);
        console.log("activeRoot(0):", vm.toString(RoutePolicyImmutableRoot(proxy).activeRoot(address(0))));
        console.log("Next steps: transfer proxy ownership to the chain-local multisig, then rotate");
        console.log("            the root via RotateRoutePolicyRoot to activate the policy.");
    }
}
