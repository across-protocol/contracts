// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";
import { RoutePolicyImmutableRoot } from "../../contracts/periphery/counterfactual/RoutePolicyImmutableRoot.sol";
import { WithdrawImplementation } from "../../contracts/periphery/counterfactual/WithdrawImplementation.sol";

/// @notice Shared config loader and resolver for counterfactual deploy scripts.
/// Reads operational params from config.toml and resolves chain-specific values
/// from Constants and DeployedAddresses.
abstract contract CounterfactualConfig is DeploymentUtils {
    string constant CONFIG_PATH = "./script/counterfactual/config.toml";

    /// @dev Genesis root every chain's RoutePolicy implementation is constructed with. Must be the
    ///      same on every chain so the implementation — and therefore the proxy — lands at the same
    ///      CREATE2 address everywhere. The real per-chain root is applied later via an
    ///      `upgradeToAndCall` rotation, which does not change the proxy's address. See README.md.
    bytes32 internal constant GENESIS_ROUTE_POLICY_ROOT = bytes32(0);

    /// @dev Default CREATE2 salt when config.toml has no top-level `deploySalt` key. Preserves the
    ///      historical `bytes32(0)` addresses.
    bytes32 internal constant DEFAULT_DEPLOY_SALT = bytes32(0);

    struct OperationalConfig {
        address signer;
        address ownerAndDirectWithdrawer;
    }

    function _loadCounterfactualConfig() internal {
        _loadConfig(CONFIG_PATH, false);
    }

    /// @dev CREATE2 salt for every counterfactual contract, read from the OPTIONAL top-level
    ///      `deploySalt` key in config.toml (a single global value, not per-chain). Defaults to
    ///      `bytes32(0)` when absent.
    ///
    ///      The salt MUST be identical across all chains — it feeds the factory, dispatcher, and
    ///      RoutePolicy proxy addresses, which feed the clone address. Sourcing it from a single
    ///      top-level key in the one shared config file makes that uniformity structural: there is
    ///      no per-chain salt to accidentally diverge. Changing it produces a fresh, parallel set of
    ///      addresses on every chain (e.g. a versioned "v2" redeploy) — do so deliberately.
    function _deploySalt() internal view returns (bytes32) {
        // Read the raw file (not via StdConfig, which only models per-chain tables and ignores
        // top-level scalar keys). No env resolution needed — the salt contains no ${VAR} patterns.
        string memory content = vm.readFile(CONFIG_PATH);
        if (vm.keyExistsToml(content, "$.deploySalt")) {
            return vm.parseTomlBytes32(content, "$.deploySalt");
        }
        return DEFAULT_DEPLOY_SALT;
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

    /// @dev Chain-local multisig that should own the RoutePolicy proxy (and rotate its root) after
    ///      genesis deployment. Reuses `ownerAndDirectWithdrawer` — the same chain-local multisig
    ///      used for the AdminWithdrawManager. The genesis owner is the deployer EOA; this is the
    ///      address ownership is transferred to as a post-deploy step.
    function _loadRoutePolicyOwner() internal returns (address) {
        _loadCounterfactualConfig();
        address owner = config.get("ownerAndDirectWithdrawer").toAddress();
        require(owner != address(0), "config: ownerAndDirectWithdrawer is zero or missing for chain");
        return owner;
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

    // --- CREATE2 init-code builders (single source of truth shared by deploy + predict paths) ---

    /// @dev `AdminWithdrawManager` is deployed with the deployer as initial owner/directWithdrawer
    ///      and the config signer. All three are global (not chain-specific), so the manager lands
    ///      at the same CREATE2 address on every chain.
    function _adminWithdrawManagerInitCode(address deployer, address signer) internal pure returns (bytes memory) {
        return abi.encodePacked(type(AdminWithdrawManager).creationCode, abi.encode(deployer, deployer, signer));
    }

    /// @dev The `WithdrawImplementation` immutable `admin` is the `AdminWithdrawManager`. Since that
    ///      address is global (see above), the withdraw impl also lands at the same address on every
    ///      chain. NOTE: the withdraw impl is NOT part of clone identity (it lives in the policy
    ///      merkle tree), so its address uniformity is operational convenience, not a hard
    ///      requirement for clone-address consistency.
    function _withdrawImplInitCode(address adminWithdrawManager) internal pure returns (bytes memory) {
        return abi.encodePacked(type(WithdrawImplementation).creationCode, abi.encode(adminWithdrawManager));
    }

    /// @dev `RoutePolicyImmutableRoot` implementation init code. Constructed with the genesis root
    ///      so it is identical across chains.
    function _routePolicyImplInitCode() internal pure returns (bytes memory) {
        return abi.encodePacked(type(RoutePolicyImmutableRoot).creationCode, abi.encode(GENESIS_ROUTE_POLICY_ROOT));
    }

    /// @dev `ERC1967Proxy` init code for the RoutePolicy proxy: points at `impl` and initializes
    ///      the proxy with the deployer EOA as owner. Both inputs must be identical across chains
    ///      for the proxy (= `cloneArgs.routePolicyAddress`) to land at the same address everywhere.
    function _routePolicyProxyInitCode(address impl, address deployer) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(impl, abi.encodeCall(RoutePolicyImmutableRoot.initialize, (deployer)))
            );
    }

    // --- CREATE2 address predictions ---

    function _predictAdminWithdrawManager(address deployer, address signer) internal view returns (address) {
        return _predictCreate2(_deploySalt(), _adminWithdrawManagerInitCode(deployer, signer));
    }

    function _predictWithdrawImpl(address adminWithdrawManager) internal view returns (address) {
        return _predictCreate2(_deploySalt(), _withdrawImplInitCode(adminWithdrawManager));
    }

    function _predictRoutePolicyImpl() internal view returns (address) {
        return _predictCreate2(_deploySalt(), _routePolicyImplInitCode());
    }

    function _predictRoutePolicyProxy(address deployer) internal view returns (address) {
        return _predictCreate2(_deploySalt(), _routePolicyProxyInitCode(_predictRoutePolicyImpl(), deployer));
    }
}
