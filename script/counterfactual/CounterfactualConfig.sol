// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { DeploymentUtils } from "../utils/DeploymentUtils.sol";

/// @notice Shared config loader and resolver for counterfactual deploy scripts.
/// Reads operational params from config.json and resolves chain-specific values
/// from Constants and DeployedAddresses.
abstract contract CounterfactualConfig is DeploymentUtils {
    string constant CONFIG_PATH = "script/counterfactual/config.json";
    string constant MULTISIGS_PATH = "script/mintburn/prod-readiness-multisigs.json";

    struct OperationalConfig {
        address signer;
        address ownerAndDirectWithdrawer;
    }

    function _loadOperationalConfig() internal view returns (OperationalConfig memory cfg) {
        string memory json = vm.readFile(CONFIG_PATH);
        cfg.signer = vm.parseJsonAddress(json, ".signer");
        require(cfg.signer != address(0), "config: signer is zero");
        string memory chainKey = string.concat(".ownerAndDirectWithdrawer.", vm.toString(block.chainid));
        cfg.ownerAndDirectWithdrawer = vm.parseJsonAddress(json, chainKey);
        require(
            cfg.ownerAndDirectWithdrawer != address(0),
            "config: ownerAndDirectWithdrawer is zero or missing for chain"
        );
    }

    /// @dev Reads the signer address from config.json (global across all chains).
    function _loadSigner() internal view returns (address) {
        string memory json = vm.readFile(CONFIG_PATH);
        address s = vm.parseJsonAddress(json, ".signer");
        require(s != address(0), "config: signer is zero");
        return s;
    }

    /// @dev Reads the multisig address for the current chain from prod-readiness-multisigs.json.
    /// Falls back to the fallbackEOA if no chain-specific entry exists.
    function _resolveMultisig() internal view returns (address) {
        string memory json = vm.readFile(MULTISIGS_PATH);
        string memory chainKey = string.concat(".", vm.toString(block.chainid));
        // Try chain-specific key first, fall back to fallbackEOA.
        try vm.parseJsonAddress(json, chainKey) returns (address addr) {
            require(addr != address(0), "multisig: zero address for chain");
            return addr;
        } catch {
            address fallbackAddr = vm.parseJsonAddress(json, ".fallbackEOA");
            require(fallbackAddr != address(0), "multisig: fallbackEOA is zero");
            return fallbackAddr;
        }
    }

    function _resolveSpokePool() internal view returns (address) {
        return getDeployedAddress("SpokePool", block.chainid, true);
    }

    function _resolveWrappedNativeToken() internal view returns (address) {
        return getWrappedNativeToken(block.chainid);
    }

    /// @dev Tries both casings to handle inconsistency in deployed-addresses.json.
    function _resolveCctpPeriphery() internal view returns (address) {
        address addr = getDeployedAddress("SponsoredCCTPSrcPeriphery", block.chainid, false);
        if (addr == address(0)) addr = getDeployedAddress("SponsoredCctpSrcPeriphery", block.chainid, false);
        return addr;
    }

    function _resolveOftPeriphery() internal view returns (address) {
        return getDeployedAddress("SponsoredOFTSrcPeriphery", block.chainid, false);
    }
}
