// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { Variable, TypeKind } from "forge-std/LibVariable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CounterfactualChainConfig } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { CounterfactualBeaconBootstrap } from "../../contracts/periphery/counterfactual/CounterfactualBeaconBootstrap.sol";
import { ICounterfactualBeacon } from "../../contracts/interfaces/ICounterfactualBeacon.sol";
import { CounterfactualDeposit } from "../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";

/// @notice Shared config loader/resolver for counterfactual deploy scripts: operational params from
/// config.toml, chain-specific values from Constants and DeployedAddresses.
abstract contract CounterfactualConfig is DeploymentUtils {
    string constant CONFIG_PATH = "./script/counterfactual/config.toml";

    /// @dev Synthetic "globals" section in config.toml. Top-level TOML keys must resolve to a chain id
    ///      (StdConfig reverts otherwise), so chain id 0 — not a real chain — hosts cross-chain-global
    ///      values like the deploy salt. See the `[0]` section in config.toml.
    uint256 internal constant GLOBALS_CHAIN_ID = 0;

    struct OperationalConfig {
        address signer;
        address ownerAndDirectWithdrawer;
    }

    /// @dev Idempotent: the StdConfig helper is fork-persistent, so a second load would only re-parse the
    ///      TOML for nothing (the check scripts call this once per chain across ~24 forks).
    function _loadCounterfactualConfig() internal {
        if (address(config) == address(0)) _loadConfig(CONFIG_PATH, false);
    }

    // --- Global CREATE2 salt + deterministic-address helpers for the singleton infra contracts ------------
    // Factory, bootstrap, beacon proxy and dispatcher are deployed via CREATE2 with this single salt so they
    // land at identical addresses on every chain — the foundation of the chain-agnostic-leaf design. Reading
    // it from one global config value keeps every script (and every chain) in lockstep; bump it to coordinate
    // a fresh cross-chain redeploy.

    /// @notice Global CREATE2 salt shared by all counterfactual infra deployments. Read from the `[0]`
    ///         globals section of config.toml (`[0.bytes32] deploySalt`); defaults to `bytes32(0)` if unset.
    function _deploySalt() internal returns (bytes32) {
        if (address(config) == address(0)) _loadCounterfactualConfig();
        Variable memory v = config.get(GLOBALS_CHAIN_ID, "deploySalt");
        return v.ty.kind == TypeKind.Bytes32 ? v.toBytes32() : bytes32(0);
    }

    /// @dev CREATE2 init code for the beacon proxy: an ERC1967Proxy over the chain-identical bootstrap,
    ///      initialized with `deployer` as bootstrap owner. Chain-invariant (bootstrap address + deployer
    ///      both are), so the proxy address is identical everywhere.
    function _beaconProxyInitCode(address deployer) internal returns (bytes memory) {
        address bootstrap = _predictCreate2(_deploySalt(), type(CounterfactualBeaconBootstrap).creationCode);
        return
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(bootstrap, abi.encodeCall(CounterfactualBeaconBootstrap.initialize, (deployer)))
            );
    }

    /// @notice Predicts the chain-invariant beacon proxy address for the given deployer (bootstrap owner).
    function _predictBeaconProxy(address deployer) internal returns (address) {
        return _predictCreate2(_deploySalt(), _beaconProxyInitCode(deployer));
    }

    /// @dev CREATE2 init code for the dispatcher (CounterfactualDeposit) bound to the beacon proxy.
    function _dispatcherInitCode(address proxy) internal pure returns (bytes memory) {
        return abi.encodePacked(type(CounterfactualDeposit).creationCode, abi.encode(ICounterfactualBeacon(proxy)));
    }

    /// @notice Predicts the chain-invariant dispatcher address bound to the given beacon proxy.
    function _predictDispatcher(address proxy) internal returns (address) {
        return _predictCreate2(_deploySalt(), _dispatcherInitCode(proxy));
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

    /// @dev Reads the signer address from config.toml.
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

    /// @dev Cap on the submitter-chosen Circle fast-transfer fee (vanilla CCTP), in bps of the burned
    ///      amount. Per-chain value from config.toml (`[N.uint]`), required on every chain; zero is a
    ///      valid value (0 ⇒ standard transfers only), unlike the `_maxExecutionFee` caps.
    function _usdcCctpMaxFeeBps() internal returns (uint256) {
        if (address(config) == address(0)) _loadCounterfactualConfig();
        Variable memory v = config.get("usdcCctpMaxFeeBps");
        require(v.ty.kind == TypeKind.Uint256, "config: usdcCctpMaxFeeBps not configured for this chain");
        return v.toUint256();
    }

    /// @dev Resolves a max-execution-fee cap for `token` from this chain's config.toml value (`key` in
    ///      the `[N.uint256]` section), taken verbatim as the full onchain amount in the token's own
    ///      decimals — e.g. 2 USDC is 2000000 on 6-decimal chains but 2000000000000000000 on BSC (18).
    ///      One config value serves every bridge type for the token. Returns 0 (route not configured)
    ///      when the token is unset on this chain; reverts if the token is set but the config key is
    ///      missing OR zero, so a beacon impl can't deploy with an unconfigured (or accidentally
    ///      zero — nonzero fees all revert) cap for a live token.
    function _maxExecutionFee(string memory key, address token) internal returns (uint256) {
        if (token == address(0)) return 0;
        if (address(config) == address(0)) _loadCounterfactualConfig();
        Variable memory v = config.get(key);
        require(v.ty.kind == TypeKind.Uint256, string.concat("config: ", key, " not configured for this chain"));
        uint256 fee = v.toUint256();
        require(fee != 0, string.concat("config: ", key, " is zero but its token is configured on this chain"));
        return fee;
    }

    /// @dev An optional `[<chainId>.address]` value: absent (or explicitly zero) resolves to `address(0)`,
    ///      which every caller turns into `RouteNotConfigured`. Used for the V5 stack, whose addresses have
    ///      no on-chain source to resolve from and are placeholders until that chain's V5 deploy lands.
    function _optionalAddress(string memory key) internal returns (address) {
        if (address(config) == address(0)) _loadCounterfactualConfig();
        Variable memory v = config.get(key);
        return v.ty.kind == TypeKind.Address ? v.toAddress() : address(0);
    }

    /// @dev A token's USD price (1e18-fixed) from the `[0]` globals — chain-invariant, so it is configured
    ///      once rather than per chain. Returns 0 when the token is absent here (nothing to price) or the
    ///      key is unset; 0 means unpriced, which SKIPS the stable floor for every pair touching the token.
    ///      That is the intended value for the volatile tokens, so unlike `_maxExecutionFee` this does not
    ///      reject a zero.
    function _stablePrice(string memory key, address token) internal returns (uint256) {
        if (token == address(0)) return 0;
        if (address(config) == address(0)) _loadCounterfactualConfig();
        Variable memory v = config.get(GLOBALS_CHAIN_ID, key);
        return v.ty.kind == TypeKind.Uint256 ? v.toUint256() : 0;
    }

    /// @dev Standard Aave/Compound-style native sentinel, returned by `beacon.nativeToken()` on chains whose
    ///      "native or equivalent" SpokePool route is paid in `msg.value` (input token is then
    ///      `beacon.wrappedNativeToken()`). Mirrors `CounterfactualDepositSpokePool.NATIVE_SENTINEL`.
    address internal constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Resolves the "native or equivalent" SpokePool input token. Defaults to `NATIVE_SENTINEL` (every
    ///      chain with a wrapped native token supports the msg.value-wrap path); a `.NATIVE_TOKEN.<chainId>`
    ///      override in constants.json forces an ERC-20 instead, bypassing the msg.value path. Without a
    ///      `.WRAPPED_NATIVE_TOKENS.<chainId>` entry the sentinel would brick at execution (wrapped native 0 →
    ///      `RouteNotConfigured`), so we fall back to `address(0)` so the leaf cleanly RouteNotConfigured's.
    function _resolveNativeToken() internal view returns (address) {
        string memory path = string.concat(".NATIVE_TOKEN.", vm.toString(block.chainid));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        if (_resolveWrappedNativeToken() == address(0)) return address(0);
        return NATIVE_SENTINEL;
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

    /// @dev Resolves the Circle CCTP v2 TokenMessenger from constants.json: `.L2_ADDRESS_MAP.<chainId>` for
    ///      L2s, `.L1_ADDRESS_MAP.<chainId>` for L1. address(0) when absent (no vanilla CCTP route).
    function _resolveCctpTokenMessenger() internal view returns (address) {
        string memory chainIdStr = vm.toString(block.chainid);
        string memory l2Path = string.concat(".L2_ADDRESS_MAP.", chainIdStr, ".cctpV2TokenMessenger");
        if (vm.keyExists(file, l2Path)) return vm.parseJsonAddress(file, l2Path);
        string memory l1Path = string.concat(".L1_ADDRESS_MAP.", chainIdStr, ".cctpV2TokenMessenger");
        if (vm.keyExists(file, l1Path)) return vm.parseJsonAddress(file, l1Path);
        return address(0);
    }

    /// @dev Resolves native (Circle-issued or chain-canonical) USDC from constants.json
    ///      (`.USDC.<chainId>`); address(0) if absent. Bridged USDC.e is a SEPARATE token with its own
    ///      slot — see `_resolveUsdce`.
    function _resolveUsdc() internal view returns (address) {
        if (vm.keyExists(file, string.concat(".USDC.", vm.toString(block.chainid)))) {
            return getUSDCAddress(block.chainid);
        }
        return address(0);
    }

    /// @dev Resolves bridged USDC.e from constants.json (`.USDCe.<chainId>`), but only where it is a
    ///      token DISTINCT from native USDC (on mainnet the `.USDCe` entry aliases native USDC — that is
    ///      not a second token). address(0) when absent or aliased. USDC.e serves SpokePool routes only:
    ///      bridged USDC has no CCTP burn path.
    function _resolveUsdce(address usdc) internal view returns (address) {
        string memory path = string.concat(".USDCe.", vm.toString(block.chainid));
        if (!vm.keyExists(file, path)) return address(0);
        address usdce = vm.parseJsonAddress(file, path);
        return usdce == usdc ? address(0) : usdce;
    }

    /// @dev Resolves USDT from constants.json (`.USDT.<chainId>`); address(0) if absent. Mainly needed for
    ///      Tron (`CounterfactualDepositSpokePoolTr` reads `beacon.usdt()`); 0 elsewhere is fine. Without a
    ///      Tron `.USDT.<chainId>` entry the Tron beacon would bake `usdt = 0` and brick every Tron SpokePool
    ///      route with `RouteNotConfigured`, so `_buildChainConfig` rejects it below.
    function _resolveUsdt() internal view returns (address) {
        string memory path = string.concat(".USDT.", vm.toString(block.chainid));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    /// @dev Resolves WBTC from constants.json (`.WBTC.<chainId>`); address(0) if absent (route not configured).
    function _resolveWbtc() internal view returns (address) {
        string memory path = string.concat(".WBTC.", vm.toString(block.chainid));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    /// @dev Resolves canonical WETH from constants.json (`.WETH.<chainId>`); address(0) if absent. Distinct
    ///      from `_resolveWrappedNativeToken` (the wrapped GAS token) — identical only on ETH-gas chains.
    function _resolveWeth() internal view returns (address) {
        string memory path = string.concat(".WETH.", vm.toString(block.chainid));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    /// @dev Resolves pathUSD from constants.json (`.pathUSD.<chainId>`); address(0) if absent. Tempo only
    ///      today, where it is the TIP-20 settlement token that gas is denominated in. It has no wrapped
    ///      form, so `_resolveWrappedNativeToken` stays zero there and Tempo gets no msg.value route — this
    ///      adds an ordinary ERC-20 input token, nothing more.
    function _resolvePathUsd() internal view returns (address) {
        string memory path = string.concat(".pathUSD.", vm.toString(block.chainid));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    /// @dev Resolves USDG (Global Dollar) from constants.json (`.USDG.<chainId>`); address(0) if absent.
    ///      Robinhood only today — upstream's separate `USDG-MAINNET` symbol is deliberately not folded into
    ///      the USDG map, so mainnet resolves zero here. See `src/consts.ts`.
    function _resolveUsdg() internal view returns (address) {
        string memory path = string.concat(".USDG.", vm.toString(block.chainid));
        if (vm.keyExists(file, path)) return vm.parseJsonAddress(file, path);
        return address(0);
    }

    // --- Beacon config as a selector-indexed table -------------------------------------------------------
    // One list, shared by every script that has to compare a deployed impl against what the resolvers now
    // produce (the staleness warning in DeployAllCounterfactual, the impl checker). Generated from
    // `CounterfactualChainConfig` field order, so adding a field means editing exactly one place — a
    // hand-maintained per-getter comparison silently stops covering whatever was added last.

    /// @dev Number of config getters on the beacon; equals the field count of `CounterfactualChainConfig`.
    uint256 internal constant BEACON_CONFIG_GETTERS = 46;

    /// @notice Every beacon config getter: its selector and its name, in struct order.
    function _beaconConfigGetters() internal pure returns (bytes4[46] memory sels, string[46] memory names) {
        sels[0] = ICounterfactualBeacon.signer.selector;
        names[0] = "signer";
        sels[1] = ICounterfactualBeacon.gateway.selector;
        names[1] = "gateway";
        sels[2] = ICounterfactualBeacon.usdc.selector;
        names[2] = "usdc";
        sels[3] = ICounterfactualBeacon.usdce.selector;
        names[3] = "usdce";
        sels[4] = ICounterfactualBeacon.usdt.selector;
        names[4] = "usdt";
        sels[5] = ICounterfactualBeacon.wbtc.selector;
        names[5] = "wbtc";
        sels[6] = ICounterfactualBeacon.weth.selector;
        names[6] = "weth";
        sels[7] = ICounterfactualBeacon.pathUsd.selector;
        names[7] = "pathUsd";
        sels[8] = ICounterfactualBeacon.usdg.selector;
        names[8] = "usdg";
        sels[9] = ICounterfactualBeacon.spokePool.selector;
        names[9] = "spokePool";
        sels[10] = ICounterfactualBeacon.wrappedNativeToken.selector;
        names[10] = "wrappedNativeToken";
        sels[11] = ICounterfactualBeacon.nativeToken.selector;
        names[11] = "nativeToken";
        sels[12] = ICounterfactualBeacon.cctpSrcPeriphery.selector;
        names[12] = "cctpSrcPeriphery";
        sels[13] = ICounterfactualBeacon.cctpTokenMessenger.selector;
        names[13] = "cctpTokenMessenger";
        sels[14] = ICounterfactualBeacon.cctpSourceDomain.selector;
        names[14] = "cctpSourceDomain";
        sels[15] = ICounterfactualBeacon.oftSrcPeriphery.selector;
        names[15] = "oftSrcPeriphery";
        sels[16] = ICounterfactualBeacon.oftSrcEid.selector;
        names[16] = "oftSrcEid";
        sels[17] = ICounterfactualBeacon.usdtOft.selector;
        names[17] = "usdtOft";
        sels[18] = ICounterfactualBeacon.spokePoolDepositExecutor.selector;
        names[18] = "spokePoolDepositExecutor";
        sels[19] = ICounterfactualBeacon.cctpDepositExecutor.selector;
        names[19] = "cctpDepositExecutor";
        sels[20] = ICounterfactualBeacon.oftDepositExecutor.selector;
        names[20] = "oftDepositExecutor";
        sels[21] = ICounterfactualBeacon.sameChainExecutor.selector;
        names[21] = "sameChainExecutor";
        sels[22] = ICounterfactualBeacon.usdcSpokePoolMaxExecutionFee.selector;
        names[22] = "usdcSpokePoolMaxExecutionFee";
        sels[23] = ICounterfactualBeacon.usdceSpokePoolMaxExecutionFee.selector;
        names[23] = "usdceSpokePoolMaxExecutionFee";
        sels[24] = ICounterfactualBeacon.usdtSpokePoolMaxExecutionFee.selector;
        names[24] = "usdtSpokePoolMaxExecutionFee";
        sels[25] = ICounterfactualBeacon.wethSpokePoolMaxExecutionFee.selector;
        names[25] = "wethSpokePoolMaxExecutionFee";
        sels[26] = ICounterfactualBeacon.wbtcSpokePoolMaxExecutionFee.selector;
        names[26] = "wbtcSpokePoolMaxExecutionFee";
        sels[27] = ICounterfactualBeacon.pathUsdSpokePoolMaxExecutionFee.selector;
        names[27] = "pathUsdSpokePoolMaxExecutionFee";
        sels[28] = ICounterfactualBeacon.usdgSpokePoolMaxExecutionFee.selector;
        names[28] = "usdgSpokePoolMaxExecutionFee";
        sels[29] = ICounterfactualBeacon.usdcSameChainMaxExecutionFee.selector;
        names[29] = "usdcSameChainMaxExecutionFee";
        sels[30] = ICounterfactualBeacon.usdceSameChainMaxExecutionFee.selector;
        names[30] = "usdceSameChainMaxExecutionFee";
        sels[31] = ICounterfactualBeacon.usdtSameChainMaxExecutionFee.selector;
        names[31] = "usdtSameChainMaxExecutionFee";
        sels[32] = ICounterfactualBeacon.wethSameChainMaxExecutionFee.selector;
        names[32] = "wethSameChainMaxExecutionFee";
        sels[33] = ICounterfactualBeacon.wbtcSameChainMaxExecutionFee.selector;
        names[33] = "wbtcSameChainMaxExecutionFee";
        sels[34] = ICounterfactualBeacon.pathUsdSameChainMaxExecutionFee.selector;
        names[34] = "pathUsdSameChainMaxExecutionFee";
        sels[35] = ICounterfactualBeacon.usdgSameChainMaxExecutionFee.selector;
        names[35] = "usdgSameChainMaxExecutionFee";
        sels[36] = ICounterfactualBeacon.usdcCctpMaxExecutionFee.selector;
        names[36] = "usdcCctpMaxExecutionFee";
        sels[37] = ICounterfactualBeacon.usdtOftMaxExecutionFee.selector;
        names[37] = "usdtOftMaxExecutionFee";
        sels[38] = ICounterfactualBeacon.usdcCctpMaxFeeBps.selector;
        names[38] = "usdcCctpMaxFeeBps";
        sels[39] = ICounterfactualBeacon.usdcStablePrice.selector;
        names[39] = "usdcStablePrice";
        sels[40] = ICounterfactualBeacon.usdceStablePrice.selector;
        names[40] = "usdceStablePrice";
        sels[41] = ICounterfactualBeacon.usdtStablePrice.selector;
        names[41] = "usdtStablePrice";
        sels[42] = ICounterfactualBeacon.pathUsdStablePrice.selector;
        names[42] = "pathUsdStablePrice";
        sels[43] = ICounterfactualBeacon.usdgStablePrice.selector;
        names[43] = "usdgStablePrice";
        sels[44] = ICounterfactualBeacon.wethStablePrice.selector;
        names[44] = "wethStablePrice";
        sels[45] = ICounterfactualBeacon.wbtcStablePrice.selector;
        names[45] = "wbtcStablePrice";
    }

    /// @notice The value each getter should return for `c`, as a raw 32-byte word, in the same order.
    function _beaconConfigWords(CounterfactualChainConfig memory c) internal pure returns (bytes32[46] memory w) {
        w[0] = bytes32(uint256(uint160(c.signer)));
        w[1] = bytes32(uint256(uint160(c.gateway)));
        w[2] = bytes32(uint256(uint160(c.usdc)));
        w[3] = bytes32(uint256(uint160(c.usdce)));
        w[4] = bytes32(uint256(uint160(c.usdt)));
        w[5] = bytes32(uint256(uint160(c.wbtc)));
        w[6] = bytes32(uint256(uint160(c.weth)));
        w[7] = bytes32(uint256(uint160(c.pathUsd)));
        w[8] = bytes32(uint256(uint160(c.usdg)));
        w[9] = bytes32(uint256(uint160(c.spokePool)));
        w[10] = bytes32(uint256(uint160(c.wrappedNativeToken)));
        w[11] = bytes32(uint256(uint160(c.nativeToken)));
        w[12] = bytes32(uint256(uint160(c.cctpSrcPeriphery)));
        w[13] = bytes32(uint256(uint160(c.cctpTokenMessenger)));
        w[14] = bytes32(uint256(c.cctpSourceDomain));
        w[15] = bytes32(uint256(uint160(c.oftSrcPeriphery)));
        w[16] = bytes32(uint256(c.oftSrcEid));
        w[17] = bytes32(uint256(uint160(c.usdtOft)));
        w[18] = bytes32(uint256(uint160(c.spokePoolDepositExecutor)));
        w[19] = bytes32(uint256(uint160(c.cctpDepositExecutor)));
        w[20] = bytes32(uint256(uint160(c.oftDepositExecutor)));
        w[21] = bytes32(uint256(uint160(c.sameChainExecutor)));
        w[22] = bytes32(uint256(c.usdcSpokePoolMaxExecutionFee));
        w[23] = bytes32(uint256(c.usdceSpokePoolMaxExecutionFee));
        w[24] = bytes32(uint256(c.usdtSpokePoolMaxExecutionFee));
        w[25] = bytes32(uint256(c.wethSpokePoolMaxExecutionFee));
        w[26] = bytes32(uint256(c.wbtcSpokePoolMaxExecutionFee));
        w[27] = bytes32(uint256(c.pathUsdSpokePoolMaxExecutionFee));
        w[28] = bytes32(uint256(c.usdgSpokePoolMaxExecutionFee));
        w[29] = bytes32(uint256(c.usdcSameChainMaxExecutionFee));
        w[30] = bytes32(uint256(c.usdceSameChainMaxExecutionFee));
        w[31] = bytes32(uint256(c.usdtSameChainMaxExecutionFee));
        w[32] = bytes32(uint256(c.wethSameChainMaxExecutionFee));
        w[33] = bytes32(uint256(c.wbtcSameChainMaxExecutionFee));
        w[34] = bytes32(uint256(c.pathUsdSameChainMaxExecutionFee));
        w[35] = bytes32(uint256(c.usdgSameChainMaxExecutionFee));
        w[36] = bytes32(uint256(c.usdcCctpMaxExecutionFee));
        w[37] = bytes32(uint256(c.usdtOftMaxExecutionFee));
        w[38] = bytes32(uint256(c.usdcCctpMaxFeeBps));
        w[39] = bytes32(uint256(c.usdcStablePrice));
        w[40] = bytes32(uint256(c.usdceStablePrice));
        w[41] = bytes32(uint256(c.usdtStablePrice));
        w[42] = bytes32(uint256(c.pathUsdStablePrice));
        w[43] = bytes32(uint256(c.usdgStablePrice));
        w[44] = bytes32(uint256(c.wethStablePrice));
        w[45] = bytes32(uint256(c.wbtcStablePrice));
    }

    /// @dev Staticcall `selector` on `target`, returning the single word it produced. `ok` is false when the
    ///      call reverts or returns a non-word — which is how an impl predating a getter reports itself
    ///      instead of aborting the whole run.
    function _tryReadBeaconWord(address target, bytes4 selector) internal view returns (bool ok, bytes32 word) {
        (bool success, bytes memory ret) = target.staticcall(abi.encodeWithSelector(selector));
        if (!success || ret.length != 32) return (false, bytes32(0));
        return (true, abi.decode(ret, (bytes32)));
    }

    /// @notice Builds the per-chain `CounterfactualChainConfig` baked into the chain-specific
    ///         `CounterfactualBeacon` impl. Missing values resolve to 0 (route simply not configured).
    ///         `_loadCounterfactualConfig()` must run first — it does, via `_loadSigner` below.
    function _buildChainConfig() internal returns (CounterfactualChainConfig memory cfg) {
        cfg.signer = _loadSigner();
        cfg.spokePool = _resolveSpokePool();
        cfg.wrappedNativeToken = _resolveWrappedNativeToken();
        cfg.nativeToken = _resolveNativeToken();
        cfg.cctpSrcPeriphery = _resolveCctpPeriphery();
        cfg.cctpSourceDomain = hasCctpDomain(block.chainid) ? getCircleDomainId(block.chainid) : 0;
        cfg.cctpTokenMessenger = _resolveCctpTokenMessenger();
        cfg.oftSrcPeriphery = _resolveOftPeriphery();
        cfg.oftSrcEid = hasOftEid(block.chainid) ? uint32(getOftEid(block.chainid)) : 0;
        cfg.usdc = _resolveUsdc();
        cfg.usdce = _resolveUsdce(cfg.usdc);
        cfg.usdt = _resolveUsdt();
        cfg.wbtc = _resolveWbtc();
        cfg.weth = _resolveWeth();
        cfg.pathUsd = _resolvePathUsd();
        cfg.usdg = _resolveUsdg();
        // --- Execution-fee caps. ONE config value per token (its raw onchain amount, in the token's own
        //     decimals) feeds every bridge that can carry it: SpokePool and same-chain for all of them, plus
        //     CCTP for USDC and OFT for USDT. A leaf names which cap to enforce via its
        //     `maxExecutionFeeGetter` selector, and each is required non-zero wherever its token resolves.
        uint256 usdcMaxExecutionFee = _maxExecutionFee("usdcMaxExecutionFee", cfg.usdc);
        cfg.usdcSpokePoolMaxExecutionFee = usdcMaxExecutionFee;
        cfg.usdcSameChainMaxExecutionFee = usdcMaxExecutionFee;
        cfg.usdcCctpMaxExecutionFee = usdcMaxExecutionFee;
        uint256 usdceMaxExecutionFee = _maxExecutionFee("usdceMaxExecutionFee", cfg.usdce);
        cfg.usdceSpokePoolMaxExecutionFee = usdceMaxExecutionFee;
        cfg.usdceSameChainMaxExecutionFee = usdceMaxExecutionFee;
        uint256 usdtMaxExecutionFee = _maxExecutionFee("usdtMaxExecutionFee", cfg.usdt);
        cfg.usdtSpokePoolMaxExecutionFee = usdtMaxExecutionFee;
        cfg.usdtSameChainMaxExecutionFee = usdtMaxExecutionFee;
        cfg.usdtOftMaxExecutionFee = usdtMaxExecutionFee;
        // Denominated in canonical WETH (18 decimals) and required only where WETH exists. On ETH-gas
        // chains the same value caps the native msg.value route (wrapped native IS WETH there); non-ETH-gas
        // chains do not get wrapped-native routes, so no cap is denominated in WBNB/WPOL/etc.
        uint256 wethMaxExecutionFee = _maxExecutionFee("wethMaxExecutionFee", cfg.weth);
        cfg.wethSpokePoolMaxExecutionFee = wethMaxExecutionFee;
        cfg.wethSameChainMaxExecutionFee = wethMaxExecutionFee;
        uint256 wbtcMaxExecutionFee = _maxExecutionFee("wbtcMaxExecutionFee", cfg.wbtc);
        cfg.wbtcSpokePoolMaxExecutionFee = wbtcMaxExecutionFee;
        cfg.wbtcSameChainMaxExecutionFee = wbtcMaxExecutionFee;
        // pathUSD and USDG have no CCTP or OFT leg — CCTP burns USDC and the OFT route is USDT0 — so their
        // config value feeds the SpokePool and same-chain caps only.
        uint256 pathUsdMaxExecutionFee = _maxExecutionFee("pathUsdMaxExecutionFee", cfg.pathUsd);
        cfg.pathUsdSpokePoolMaxExecutionFee = pathUsdMaxExecutionFee;
        cfg.pathUsdSameChainMaxExecutionFee = pathUsdMaxExecutionFee;
        uint256 usdgMaxExecutionFee = _maxExecutionFee("usdgMaxExecutionFee", cfg.usdg);
        cfg.usdgSpokePoolMaxExecutionFee = usdgMaxExecutionFee;
        cfg.usdgSameChainMaxExecutionFee = usdgMaxExecutionFee;
        // Bps cap (not token units) on the submitter-chosen Circle fast-transfer fee (vanilla CCTP).
        cfg.usdcCctpMaxFeeBps = _usdcCctpMaxFeeBps();

        // --- V5 stack. No resolver exists for any of these: they come from `[<chainId>.address]` or stay
        //     zero, which callers turn into `RouteNotConfigured` — so an unfilled entry is inert, not unsafe.
        cfg.gateway = _optionalAddress("gateway");
        cfg.usdtOft = _optionalAddress("usdtOft");
        cfg.spokePoolDepositExecutor = _optionalAddress("spokePoolDepositExecutor");
        cfg.cctpDepositExecutor = _optionalAddress("cctpDepositExecutor");
        cfg.oftDepositExecutor = _optionalAddress("oftDepositExecutor");
        cfg.sameChainExecutor = _optionalAddress("sameChainExecutor");

        // --- Prices. Chain-invariant (the floor divides one by the other and folds on-chain decimals), so
        //     they live once in the `[0]` globals rather than being repeated per chain. Baked only where the
        //     token itself resolves, so an absent token stays wholly unconfigured.
        cfg.usdcStablePrice = _stablePrice("usdcStablePrice", cfg.usdc);
        cfg.usdceStablePrice = _stablePrice("usdceStablePrice", cfg.usdce);
        cfg.usdtStablePrice = _stablePrice("usdtStablePrice", cfg.usdt);
        cfg.pathUsdStablePrice = _stablePrice("pathUsdStablePrice", cfg.pathUsd);
        cfg.usdgStablePrice = _stablePrice("usdgStablePrice", cfg.usdg);
        // WETH and WBTC are volatile: their globals are zero, so the floor is skipped for their pairs.
        cfg.wethStablePrice = _stablePrice("wethStablePrice", cfg.weth);
        cfg.wbtcStablePrice = _stablePrice("wbtcStablePrice", cfg.wbtc);
        // SpokePool is the foundational route. Baking `spokePool = 0` silently bricks every SpokePool leaf,
        // fixable only by a registry UUPS upgrade (the value is immutable on the impl). Refuse to deploy
        // without a SpokePool entry.
        require(
            cfg.spokePool != address(0),
            "config: SpokePool must be deployed on this chain (add to deployed-addresses.json)"
        );
        // Tron's `CounterfactualDepositSpokePoolTr` is USDT-only; baking `usdt = 0` bricks every Tron
        // SpokePool route. Require an explicit `.USDT.728126428` entry in constants.json before deploying.
        require(
            block.chainid != 728126428 || cfg.usdt != address(0),
            "config: USDT must be configured for Tron (add .USDT.728126428 to constants.json)"
        );
        // The sentinel means "wrap msg.value into `wrappedNativeToken`", so it's meaningless without one.
        // `_resolveNativeToken` upholds this for the default path but returns a `.NATIVE_TOKEN.<chainId>`
        // override verbatim, so guard the pairing here rather than baking a sentinel that bricks at execution.
        require(
            cfg.nativeToken != NATIVE_SENTINEL || cfg.wrappedNativeToken != address(0),
            "config: nativeToken=sentinel requires wrappedNativeToken"
        );
        // Cross-check the chain's DECLARED support surface ([N.bool] in config.toml) against what the
        // data sources actually resolve. Pure assertions in both directions: declaring a token/bridge
        // supported that the data can't back — or unsupported when the data says it's live — reverts, so
        // config.toml is always an accurate, reviewable statement of each chain's counterfactual surface.
        _validateDeclaredSupport(cfg);
    }

    /// @dev Requires every `[<chainId>.bool]` support flag in config.toml to match resolved reality.
    ///      Tokens assert on the resolved address; bridges assert on the route's full capability:
    ///      SpokePool (deployed SpokePool), sponsored CCTP (Circle domain + SponsoredCCTPSrcPeriphery),
    ///      vanilla CCTP (Circle CCTP v2 TokenMessenger), OFT (LayerZero EID + SponsoredOFTSrcPeriphery).
    ///      Missing flags revert too — every chain must declare all nine explicitly.
    function _validateDeclaredSupport(CounterfactualChainConfig memory cfg) internal {
        _checkDeclaredFlag("usdc", cfg.usdc != address(0));
        _checkDeclaredFlag("usdce", cfg.usdce != address(0));
        _checkDeclaredFlag("usdt", cfg.usdt != address(0));
        _checkDeclaredFlag("wbtc", cfg.wbtc != address(0));
        _checkDeclaredFlag("weth", cfg.weth != address(0));
        _checkDeclaredFlag("pathUsd", cfg.pathUsd != address(0));
        _checkDeclaredFlag("usdg", cfg.usdg != address(0));
        _checkDeclaredFlag("spokePool", cfg.spokePool != address(0));
        _checkDeclaredFlag("sponsoredCctp", hasCctpDomain(block.chainid) && cfg.cctpSrcPeriphery != address(0));
        _checkDeclaredFlag("vanillaCctp", cfg.cctpTokenMessenger != address(0));
        _checkDeclaredFlag("oft", hasOftEid(block.chainid) && cfg.oftSrcPeriphery != address(0));
    }

    function _checkDeclaredFlag(string memory key, bool actual) private {
        Variable memory v = config.get(key);
        require(
            v.ty.kind == TypeKind.Bool,
            string.concat("config: [", vm.toString(block.chainid), ".bool] ", key, " flag missing")
        );
        require(
            v.toBool() == actual,
            string.concat(
                "config: ",
                key,
                " declared ",
                v.toBool() ? "true" : "false",
                " but constants/broadcasts resolve it as ",
                actual ? "supported" : "unsupported"
            )
        );
    }
}
