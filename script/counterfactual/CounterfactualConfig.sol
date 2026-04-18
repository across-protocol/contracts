// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { DeploymentUtils } from "../utils/DeploymentUtils.sol";

/// @notice Shared config loader and resolver for counterfactual deploy scripts.
/// Reads operational params from config.toml and resolves chain-specific values
/// from Constants and DeployedAddresses.
abstract contract CounterfactualConfig is DeploymentUtils {
    string constant CONFIG_PATH = "./script/counterfactual/config.toml";

    struct OperationalConfig {
        address signer;
        address ownerAndDirectWithdrawer;
    }

    function _loadCounterfactualConfig() internal {
        _loadConfig(CONFIG_PATH, false);
    }

    function _loadOperationalConfig() internal returns (OperationalConfig memory cfg) {
        _loadCounterfactualConfig();
        cfg.signer = config.get("signer").toAddress();
        require(cfg.signer != address(0), "config: signer is zero");
        cfg.ownerAndDirectWithdrawer = config.get("ownerAndDirectWithdrawer").toAddress();
        require(
            cfg.ownerAndDirectWithdrawer != address(0),
            "config: ownerAndDirectWithdrawer is zero or missing for chain"
        );
    }

    /// @dev Reads the signer address from config.toml for the current chain.
    function _loadSigner() internal returns (address) {
        _loadCounterfactualConfig();
        address s = config.get("signer").toAddress();
        require(s != address(0), "config: signer is zero");
        return s;
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
