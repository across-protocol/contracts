// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { ICounterfactualBeacon } from "../../interfaces/ICounterfactualBeacon.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";

/**
 * @title CounterfactualImplementationBase
 * @notice Shared base for leaf implementations that resolves the per-chain `CounterfactualBeacon` to read
 *         chain-specific config (bridge endpoints, fee signer, token addresses) at runtime.
 * @dev Leaf implementations run under delegatecall from the counterfactual `BeaconProxy`, so `address(this)`
 *      is the proxy and the beacon lives in the proxy's standard ERC-1967 beacon slot. Reading it there
 *      means a leaf implementation needs **no immutables of its own** and stays byte-identical across
 *      chains (one CREATE2 address everywhere). A leaf carries no chain-specific address; everything chain-
 *      specific comes from `_beacon()`.
 * @custom:security-contact bugs@across.to
 */
abstract contract CounterfactualImplementationBase is ICounterfactualImplementation {
    /// @dev A chain-specific value required by the route is unset on this chain's beacon (so the route is
    ///      not live here). A single chain-agnostic leaf may sit in trees on chains that don't support it;
    ///      executing it there reverts cleanly instead of acting on a zero address.
    error RouteNotConfigured();

    /// @dev The per-chain registry that anchors this proxy (resolved from the ERC-1967 beacon slot).
    function _beacon() internal view returns (ICounterfactualBeacon) {
        return ICounterfactualBeacon(ERC1967Utils.getBeacon());
    }

    /// @dev Resolve an address by calling a no-arg `() -> address` beacon getter named by `getter` (its
    ///      4-byte selector, carried in the leaf — e.g. `beacon.usdc.selector` for a token or an OFT
    ///      periphery getter). A failed call or non-32-byte return yields `address(0)`, which callers treat
    ///      as `RouteNotConfigured`. The selector is committed in the merkle leaf (and, where applicable,
    ///      bound by the fee signature), so it is trusted input; a malformed selector can only revert here
    ///      or downstream.
    function _resolveBeaconAddress(bytes4 getter) internal view returns (address) {
        (bool ok, bytes memory ret) = address(_beacon()).staticcall(abi.encodeWithSelector(getter));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @dev Revert `RouteNotConfigured` if a beacon-resolved address is unset; otherwise pass it through.
    function _requireConfigured(address addr) internal pure returns (address) {
        if (addr == address(0)) revert RouteNotConfigured();
        return addr;
    }
}
