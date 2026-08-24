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
    ///      slot — see `_resolveUsdce`. An `[N.address] usdcOverride` entry in config.toml wins over
    ///      constants.json: it makes a chain-local stablecoin serve as the beacon's USDC (e.g. pathUSD
    ///      on Tempo) without aliasing it into the global USDC constants that other consumers read.
    function _resolveUsdc() internal returns (address) {
        address overrideAddr = _usdcOverride();
        if (overrideAddr != address(0)) return overrideAddr;
        if (vm.keyExists(file, string.concat(".USDC.", vm.toString(block.chainid)))) {
            return getUSDCAddress(block.chainid);
        }
        return address(0);
    }

    /// @dev The chain's `[N.address] usdcOverride` entry, or address(0) when it configures none. Exposed
    ///      separately so verifier scripts can assert the beacon's `usdc` against the pinned address rather
    ///      than guessing at a symbol — a TIP-20 system token's `symbol()` is unreadable under a local EVM
    ///      fork, so an address comparison is both stronger and the only reliable check for these tokens.
    function _usdcOverride() internal returns (address) {
        if (address(config) == address(0)) _loadCounterfactualConfig();
        Variable memory v = config.get("usdcOverride");
        return v.ty.kind == TypeKind.Address ? v.toAddress() : address(0);
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
        // Per-(token, bridge) execution-fee caps: a per-chain raw onchain amount in config.toml, in the
        // token's own decimals. Bridge types share the token's value. A leaf names which cap to enforce
        // via its `maxExecutionFeeGetter` selector.
        uint256 usdcMaxExecutionFee = _maxExecutionFee("usdcMaxExecutionFee", cfg.usdc);
        cfg.usdcCctpMaxExecutionFee = usdcMaxExecutionFee;
        cfg.usdcSpokePoolMaxExecutionFee = usdcMaxExecutionFee;
        uint256 usdtMaxExecutionFee = _maxExecutionFee("usdtMaxExecutionFee", cfg.usdt);
        cfg.usdtOftMaxExecutionFee = usdtMaxExecutionFee;
        cfg.usdtSpokePoolMaxExecutionFee = usdtMaxExecutionFee;
        // Denominated in canonical WETH (18 decimals) and required only where WETH exists. On ETH-gas
        // chains the same value caps the native msg.value route (wrapped native IS WETH there); non-ETH-gas
        // chains do not get wrapped-native routes, so no cap is denominated in WBNB/WPOL/etc.
        cfg.usdceSpokePoolMaxExecutionFee = _maxExecutionFee("usdceMaxExecutionFee", cfg.usdce);
        cfg.wethSpokePoolMaxExecutionFee = _maxExecutionFee("wethMaxExecutionFee", cfg.weth);
        cfg.wbtcSpokePoolMaxExecutionFee = _maxExecutionFee("wbtcMaxExecutionFee", cfg.wbtc);
        // Bps cap (not token units) on the submitter-chosen Circle fast-transfer fee (vanilla CCTP).
        cfg.usdcCctpMaxFeeBps = _usdcCctpMaxFeeBps();
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

    /// @notice Chains carrying ONLY the refund surface: no SpokePool, no CCTP/OFT periphery, no route
    ///         leaf impls — so `_buildChainConfig`'s SpokePool requirement can never be satisfied there.
    /// @dev A user can send funds to any counterfactual address on ANY EVM chain, because the address is
    ///      `f(factory, beacon, initialRoot, salt)` and none of those is chain-specific. Standing up the
    ///      beacon + factory on such a chain makes those addresses reconstructible so
    ///      `AdminWithdrawManager.signedWithdrawToUser` can return stranded funds to the creation-pinned
    ///      refund address. It does NOT make the chain a supported origin — nothing advertises or quotes
    ///      it, and with no route leaf impls deployed no bridge leaf can execute.
    ///
    ///      Membership is an explicit allowlist rather than a config.toml flag so that "deploy a beacon
    ///      with no route config" is always a reviewed code change, never a silent side effect of a
    ///      missing/incorrect TOML entry on a chain that was meant to be fully supported.
    function _isRefundOnlyChain(uint256 chainId) internal pure returns (bool) {
        return chainId == 196 || chainId == 2818; // X Layer, Morph
    }

    /// @notice The `CounterfactualChainConfig` for a refund-only chain: every route value zero.
    /// @dev Safe because the refund path reads none of them. `AdminWithdrawManager.signedWithdrawToUser`
    ///      → `CounterfactualDeposit._execute` (merkle-verifies against `activeRoot`, no beacon read) →
    ///      delegatecall `WithdrawImplementation` (holds no beacon reads at all). The dispatcher only
    ///      touches `BEACON.upgradeRoot()` inside `_updateRoot`, which the refund path never calls.
    ///      `signer` is carried for parity with other chains but is cosmetic here too — the withdraw
    ///      signature is checked against the AdminWithdrawManager's OWN `signer` storage, not the
    ///      beacon's.
    ///
    ///      Every getter returning zero also means each route leaf impl would revert
    ///      `RouteNotConfigured` if one were ever deployed and named by a leaf — the config is inert, not
    ///      merely unused. If the chain is later onboarded properly, deploy a real impl and
    ///      `upgradeToAndCall` the beacon: the proxy address (and therefore every deposit address) is
    ///      unaffected.
    function _buildRefundOnlyChainConfig() internal returns (CounterfactualChainConfig memory cfg) {
        cfg.signer = _loadSigner();
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
