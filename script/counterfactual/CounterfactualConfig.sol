// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Variable, TypeKind } from "forge-std/LibVariable.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { CounterfactualBeacon } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { CounterfactualDeposit } from "../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { ICounterfactualBeacon } from "../../contracts/interfaces/ICounterfactualBeacon.sol";

/// @notice Shared config loader and resolver for counterfactual deploy scripts.
/// Reads operational params from config.toml and resolves chain-specific values
/// from Constants and DeployedAddresses.
abstract contract CounterfactualConfig is DeploymentUtils {
    string constant CONFIG_PATH = "./script/counterfactual/config.toml";

    /// @dev Reserved "any chain" section id for global (chain-invariant) config values. StdConfig keys
    ///      everything by chain, so globals live under `[0]` (a sentinel that is never a real chain).
    uint256 internal constant GLOBAL_CONFIG_CHAIN_ID = 0;

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

    /// @dev Reads the global CREATE2 salt for the counterfactual stack from config.toml.
    ///      Stored under the reserved `[0]` ("any chain") section as `[0.bytes32] salt` — StdConfig is
    ///      chain-keyed and rejects bare top-level keys, so globals must live under a chain section. The
    ///      salt MUST be identical on every chain for cross-chain address parity (the beacon proxy, and
    ///      thus every counterfactual address, derive from it). Reverts (via `toBytes32`'s type check) if
    ///      `[0.bytes32] salt` is missing — the salt is required, not defaulted.
    function _loadSalt() internal returns (bytes32) {
        _loadCounterfactualConfig();
        Variable memory v = config.get(GLOBAL_CONFIG_CHAIN_ID, "salt");
        require(v.ty.kind == TypeKind.Bytes32, "config: missing global salt ([0.bytes32] salt in config.toml)");
        return v.toBytes32();
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

    /// @dev Circle CCTP v2 TokenMessenger for this chain (vanilla CCTP route), from constants.json. Tries
    ///      the L2 map first, then the L1 map (mainnet). Returns address(0) if not present on this chain.
    function _resolveCctpV2TokenMessenger() internal view returns (address) {
        string memory l2 = string.concat(".L2_ADDRESS_MAP.", vm.toString(block.chainid), ".cctpV2TokenMessenger");
        if (vm.keyExists(file, l2)) return vm.parseJsonAddress(file, l2);
        string memory l1 = string.concat(".L1_ADDRESS_MAP.", vm.toString(block.chainid), ".cctpV2TokenMessenger");
        if (vm.keyExists(file, l1)) return vm.parseJsonAddress(file, l1);
        return address(0);
    }

    // --- Beacon stack address derivation (deterministic across chains) ---
    //
    // The beacon PROXY address anchors every counterfactual address (each BeaconProxy embeds it), so it must
    // be identical on every chain. That holds because (a) the beacon implementation has no constructor args
    // (chain-identical creationCode), (b) the proxy is initialized with the chain-invariant `deployer` as
    // owner and a zero implementation/upgradeRoot (set after deploy), and (c) the CREATE2 `salt` is the
    // global value from config.toml. The same `deployer` AND `salt` MUST be used on every chain — both are
    // part of the (proxy init code, salt) CREATE2 preimage and therefore of the address.

    /// @dev Beacon implementation init code (no constructor args ⇒ same address on every chain for a salt).
    function _beaconImplInitCode() internal pure returns (bytes memory) {
        return type(CounterfactualBeacon).creationCode;
    }

    /// @dev Predicted beacon implementation address for `salt` (chain-invariant when `salt` is).
    function _predictBeaconImpl(bytes32 salt) internal pure returns (address) {
        return _predictCreate2(salt, _beaconImplInitCode());
    }

    /// @dev Beacon proxy init code: an ERC1967Proxy over the beacon impl, initialized with `deployer` as
    ///      owner and zero implementation/upgradeRoot. Chain-invariant when `deployer` and `salt` are.
    function _beaconProxyInitCode(address deployer, bytes32 salt) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(
                    _predictBeaconImpl(salt),
                    abi.encodeCall(CounterfactualBeacon.initialize, (deployer, address(0), bytes32(0)))
                )
            );
    }

    /// @dev Predicted beacon proxy address — the chain-invariant anchor every dispatcher/factory/clone embeds.
    function _predictBeaconProxy(address deployer, bytes32 salt) internal pure returns (address) {
        return _predictCreate2(salt, _beaconProxyInitCode(deployer, salt));
    }

    /// @dev Dispatcher (CounterfactualDeposit) init code, bound to the beacon proxy.
    function _dispatcherInitCode(address beaconProxy) internal pure returns (bytes memory) {
        return
            abi.encodePacked(type(CounterfactualDeposit).creationCode, abi.encode(ICounterfactualBeacon(beaconProxy)));
    }

    /// @dev Factory init code, bound to the beacon proxy.
    function _factoryInitCode(address beaconProxy) internal pure returns (bytes memory) {
        return abi.encodePacked(type(CounterfactualDepositFactory).creationCode, abi.encode(beaconProxy));
    }
}
