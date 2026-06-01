// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { RoutePolicyImmutableRoot } from "../../contracts/periphery/counterfactual/RoutePolicyImmutableRoot.sol";

// Rotates a RoutePolicy proxy to a new merkle root. Because the root is `immutable` on the
// implementation, "rotating the root" means: (1) deploy a new implementation carrying the new root,
// (2) call `upgradeToAndCall(newImpl, "")` on the proxy. The proxy address is unchanged, so clone
// addresses are unaffected.
//
// IMPORTANT: this is a per-chain governance action, NOT part of genesis deployment. The new
// implementation carries a chain-specific root, so its address differs per chain — that is fine and
// expected. Only the genesis implementation (bytes32(0) root) and the proxy must be uniform across
// chains; post-genesis implementations are free to diverge.
//
// Authorization: `upgradeToAndCall` is owner-gated on the proxy. After genesis the owner is the
// chain-local multisig. Two ways to run:
//   A. Owner is an EOA you control (e.g. testnet, or pre-ownership-transfer): broadcast directly
//      with MNEMONIC — this script deploys the impl and calls upgradeToAndCall in one run.
//   B. Owner is a multisig (production): run WITHOUT --broadcast to deploy the impl in simulation
//      and log the `upgradeToAndCall(newImpl, "")` calldata, then execute that call from the
//      multisig as a Safe transaction. (Or deploy the impl in a separate broadcast tx, then submit
//      only the upgrade call via the Safe.)
//
// How to run (case A):
//   source .env   # MNEMONIC, ETHERSCAN_API_KEY
//   forge script script/counterfactual/RotateRoutePolicyRoot.s.sol:RotateRoutePolicyRoot \
//     --sig "run(address,bytes32)" <proxy> <newRoot> \
//     --rpc-url $NODE_URL --broadcast --verify -vvvv
contract RotateRoutePolicyRoot is CounterfactualConfig {
    /// @param proxy   The RoutePolicy ERC1967Proxy (== cloneArgs.routePolicyAddress).
    /// @param newRoot The new merkle root to activate.
    function run(address proxy, bytes32 newRoot) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        require(proxy.code.length > 0, "proxy not deployed");
        RoutePolicyImmutableRoot policy = RoutePolicyImmutableRoot(proxy);

        bytes32 currentRoot = policy.activeRoot(address(0));
        address currentOwner = policy.owner();

        console.log("Rotating RoutePolicy root...");
        console.log("Chain ID:    ", block.chainid);
        console.log("Proxy:       ", proxy);
        console.log("Owner:       ", currentOwner);
        console.log("Current root:", vm.toString(currentRoot));
        console.log("New root:    ", vm.toString(newRoot));

        // Deploy the new implementation carrying `newRoot`. This is a chain-specific impl address.
        bytes memory implInit = abi.encodePacked(type(RoutePolicyImmutableRoot).creationCode, abi.encode(newRoot));

        vm.startBroadcast(deployerPrivateKey);
        address newImpl = _deployCreate2(_rootSalt(newRoot), implInit);
        vm.stopBroadcast();

        console.log("New implementation deployed to:", newImpl);

        bytes memory upgradeCalldata = abi.encodeCall(RoutePolicyImmutableRoot(proxy).upgradeToAndCall, (newImpl, ""));
        console.log("upgradeToAndCall calldata (submit from the owner):");
        console.logBytes(upgradeCalldata);

        // If the broadcaster is the current owner, perform the upgrade directly. Otherwise the
        // operator must submit `upgradeCalldata` to `proxy` from the multisig owner.
        if (vm.addr(deployerPrivateKey) == currentOwner) {
            vm.startBroadcast(deployerPrivateKey);
            policy.upgradeToAndCall(newImpl, "");
            vm.stopBroadcast();
            require(policy.activeRoot(address(0)) == newRoot, "rotation failed");
            console.log("Rotation complete. activeRoot is now the new root.");
        } else {
            console.log("Broadcaster is not the proxy owner; submit the calldata above from:", currentOwner);
        }
    }

    /// @dev Salt the per-chain impl deploy by the root so distinct roots get distinct addresses and
    ///      a redeploy of the same root is idempotent.
    function _rootSalt(bytes32 newRoot) private pure returns (bytes32) {
        return keccak256(abi.encodePacked("RoutePolicyImpl", newRoot));
    }
}
