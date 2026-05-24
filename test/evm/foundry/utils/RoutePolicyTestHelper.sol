// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RoutePolicy } from "../../../../contracts/periphery/counterfactual/RoutePolicy.sol";

/// @notice Deploys a `RoutePolicy` behind an ERC1967 proxy and returns the proxy as a `RoutePolicy`.
function deployRoutePolicy(address initialOwner, bytes32 initialRoot) returns (RoutePolicy) {
    RoutePolicy impl = new RoutePolicy();
    ERC1967Proxy proxy = new ERC1967Proxy(
        address(impl),
        abi.encodeCall(RoutePolicy.initialize, (initialOwner, initialRoot))
    );
    return RoutePolicy(address(proxy));
}
