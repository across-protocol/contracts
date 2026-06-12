// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { ICounterfactualBeacon } from "../../interfaces/ICounterfactualBeacon.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";

/**
 * @title CounterfactualImplementationBase
 * @notice Shared base for leaf implementations: resolves the per-chain `CounterfactualBeacon` to read
 *         chain-specific config (endpoints, fee signer, tokens) at runtime.
 * @dev Leaves run under delegatecall from the `BeaconProxy`, so `address(this)` is the proxy and the beacon
 *      sits in its ERC-1967 beacon slot. Reading config there means a leaf holds **no immutables of its
 *      own** and is byte-identical across chains (one CREATE2 address everywhere).
 * @custom:security-contact bugs@across.to
 */
abstract contract CounterfactualImplementationBase is ICounterfactualImplementation {
    /// @dev A value the route needs is unset on this chain's beacon (route not live here) — a chain-agnostic
    ///      leaf reverts cleanly rather than acting on a zero address.
    error RouteNotConfigured();

    /// @dev The per-chain registry that anchors this proxy (resolved from the ERC-1967 beacon slot).
    function _beacon() internal view returns (ICounterfactualBeacon) {
        return ICounterfactualBeacon(ERC1967Utils.getBeacon());
    }

    /// @dev Resolve an address from a no-arg `() -> address` beacon getter named by `getter`'s selector
    ///      (carried in the leaf, e.g. `beacon.usdc.selector`). A failed call / non-32-byte return yields
    ///      `address(0)`, which callers treat as `RouteNotConfigured`. The selector is merkle-committed (and
    ///      where applicable signature-bound), so trusted; a bad selector can only revert here or downstream.
    function _resolveBeaconAddress(bytes4 getter) internal view returns (address) {
        (bool ok, bytes memory ret) = address(_beacon()).staticcall(abi.encodeWithSelector(getter));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @dev Resolve a uint from a no-arg `() -> uint256` beacon getter named by `getter`'s selector (carried
    ///      in the leaf, e.g. `beacon.usdcCctpMaxExecutionFee.selector`). Reverts `RouteNotConfigured` if the
    ///      getter doesn't exist; a configured value of 0 is valid and returned as-is. Merkle/signature-bound.
    function _resolveBeaconUint(bytes4 getter) internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(_beacon()).staticcall(abi.encodeWithSelector(getter));
        if (!ok || ret.length != 32) revert RouteNotConfigured();
        return abi.decode(ret, (uint256));
    }

    /// @dev Revert `RouteNotConfigured` if a beacon-resolved address is unset; otherwise pass it through.
    function _requireConfigured(address addr) internal pure returns (address) {
        if (addr == address(0)) revert RouteNotConfigured();
        return addr;
    }
}
