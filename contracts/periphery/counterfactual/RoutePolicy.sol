// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IRoutePolicy } from "../../interfaces/IRoutePolicy.sol";

/**
 * @title RoutePolicy
 * @notice Minimal `Ownable` contract holding one merkle root that enumerates the routes a set of
 *         counterfactual clones may execute on this chain. The owner (typically a multisig) calls
 *         `approve(newRoot)` to upgrade the route set globally for every clone pointing at this policy.
 * @dev The contract address is intended to be identical across every EVM chain (deployed via the
 *      deterministic-deployment proxy with constant constructor args); each chain maintains its own
 *      independent `activeRoot` storage.
 * @custom:security-contact bugs@across.to
 */
contract RoutePolicy is IRoutePolicy, Ownable {
    /// @inheritdoc IRoutePolicy
    bytes32 public activeRoot;

    constructor(address initialOwner, bytes32 initialRoot) Ownable(initialOwner) {
        activeRoot = initialRoot;
    }

    /// @inheritdoc IRoutePolicy
    function approve(bytes32 newRoot) external onlyOwner {
        activeRoot = newRoot;
        emit Approved(newRoot);
    }
}
