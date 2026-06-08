// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { CounterfactualChainConfig } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";

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
        return getDeployedAddress("SpokePool", block.chainid, false);
    }

    function _resolveWrappedNativeToken() internal view returns (address) {
        if (vm.keyExists(file, string.concat(".WRAPPED_NATIVE_TOKENS.", vm.toString(block.chainid)))) {
            return getWrappedNativeToken(block.chainid);
        }
        return address(0);
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

    /// @dev Resolves the Circle CCTP v2 TokenMessenger for this chain from constants.json. Lives under
    ///      `.L2_ADDRESS_MAP.<chainId>.cctpV2TokenMessenger` for L2s and `.L1_ADDRESS_MAP.<chainId>` for L1.
    ///      Returns address(0) when not present (chain simply won't have the vanilla CCTP route configured).
    function _resolveCctpTokenMessenger() internal view returns (address) {
        string memory chainIdStr = vm.toString(block.chainid);
        string memory l2Path = string.concat(".L2_ADDRESS_MAP.", chainIdStr, ".cctpV2TokenMessenger");
        if (vm.keyExists(file, l2Path)) return vm.parseJsonAddress(file, l2Path);
        string memory l1Path = string.concat(".L1_ADDRESS_MAP.", chainIdStr, ".cctpV2TokenMessenger");
        if (vm.keyExists(file, l1Path)) return vm.parseJsonAddress(file, l1Path);
        return address(0);
    }

    /// @dev Resolves USDC for this chain from constants.json (`.USDC.<chainId>`); address(0) if absent.
    function _resolveUsdc() internal view returns (address) {
        if (vm.keyExists(file, string.concat(".USDC.", vm.toString(block.chainid)))) {
            return getUSDCAddress(block.chainid);
        }
        return address(0);
    }

    /// @dev Resolves USDT for this chain from constants.json (`.USDT.<chainId>`); address(0) if absent.
    ///      USDT is mainly needed for Tron (`CounterfactualDepositSpokePoolTr` resolves the input token via
    ///      `beacon.usdt()`); 0 elsewhere is fine. Until a `.USDT.<chainId>` entry exists for Tron, the Tron
    ///      beacon would bake `usdt = 0` and every Tron SpokePool route would revert `RouteNotConfigured`,
    ///      so `_buildChainConfig` rejects it explicitly below.
    function _resolveUsdt() internal view returns (address) {
        string memory path = string.concat(".USDT.", vm.toString(block.chainid));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    /// @notice Builds the per-chain `CounterfactualChainConfig` baked into the chain-specific
    ///         `CounterfactualBeacon` implementation. Missing values resolve to 0 (the chain simply won't
    ///         have that route configured). `_loadCounterfactualConfig()` must have been called first (it is,
    ///         inside `_loadSigner`, which this calls).
    function _buildChainConfig() internal returns (CounterfactualChainConfig memory cfg) {
        cfg.signer = _loadSigner();
        cfg.spokePool = _resolveSpokePool();
        cfg.wrappedNativeToken = _resolveWrappedNativeToken();
        cfg.cctpSrcPeriphery = _resolveCctpPeriphery();
        cfg.cctpSourceDomain = hasCctpDomain(block.chainid) ? getCircleDomainId(block.chainid) : 0;
        cfg.cctpTokenMessenger = _resolveCctpTokenMessenger();
        cfg.oftSrcPeriphery = _resolveOftPeriphery();
        cfg.oftSrcEid = hasOftEid(block.chainid) ? uint32(getOftEid(block.chainid)) : 0;
        cfg.usdc = _resolveUsdc();
        cfg.usdt = _resolveUsdt();
        // SpokePool is the foundational route — baking `spokePool = 0` would silently brick every
        // SpokePool leaf, and the only fix afterwards is a registry UUPS upgrade (the value is immutable
        // on the beacon implementation). Refuse to deploy on a chain without a SpokePool entry.
        require(
            cfg.spokePool != address(0),
            "config: SpokePool must be deployed on this chain (add to deployed-addresses.json)"
        );
        // Tron's `CounterfactualDepositSpokePoolTr` is USDT-only — silently baking `usdt = 0` here would
        // brick every Tron SpokePool route at execution time. Require an explicit `.USDT.728126428` entry
        // in constants.json before deploying the Tron beacon.
        require(
            block.chainid != 728126428 || cfg.usdt != address(0),
            "config: USDT must be configured for Tron (add .USDT.728126428 to constants.json)"
        );
    }
}
