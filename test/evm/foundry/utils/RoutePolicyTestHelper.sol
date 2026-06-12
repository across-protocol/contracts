// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Vm } from "forge-std/Vm.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoutePolicyImmutableRoot } from "../../../../contracts/periphery/counterfactual/RoutePolicyImmutableRoot.sol";

Vm constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/**
 * @notice Deploys a `RoutePolicyImmutableRoot` behind an ERC1967 proxy. The implementation's
 *         constructor bakes `initialRoot` into its runtime bytecode; the proxy is initialized with
 *         `initialOwner`.
 */
function deployRoutePolicy(address initialOwner, bytes32 initialRoot) returns (RoutePolicyImmutableRoot) {
    RoutePolicyImmutableRoot impl = new RoutePolicyImmutableRoot(initialRoot);
    ERC1967Proxy proxy = new ERC1967Proxy(
        address(impl),
        abi.encodeCall(RoutePolicyImmutableRoot.initialize, (initialOwner))
    );
    return RoutePolicyImmutableRoot(address(proxy));
}

/**
 * @notice Rotates the policy's active root by deploying a new implementation with `newRoot` baked
 *         in and upgrading the proxy to it. The upgrade call is pranked as `owner`.
 */
function rotateRoot(RoutePolicyImmutableRoot proxy, address owner, bytes32 newRoot) {
    RoutePolicyImmutableRoot newImpl = new RoutePolicyImmutableRoot(newRoot);
    _vm.prank(owner);
    proxy.upgradeToAndCall(address(newImpl), "");
}
