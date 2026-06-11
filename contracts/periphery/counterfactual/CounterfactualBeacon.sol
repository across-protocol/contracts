// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualBeacon } from "../../interfaces/ICounterfactualBeacon.sol";
import { CounterfactualBeaconBase } from "./CounterfactualBeaconBase.sol";

/**
 * @notice Chain-specific config baked into a `CounterfactualBeacon` implementation as `public immutable`s,
 *         so leaves read endpoints/tokens/signer from the registry and stay byte-identical across chains.
 *         Each chain deploys its own implementation with its own config.
 */
struct CounterfactualChainConfig {
    address signer;
    address spokePool;
    address wrappedNativeToken;
    /// @dev "Native" SpokePool route: the native sentinel where the deposit is `msg.value` (wrapped to
    ///      `wrappedNativeToken`), or an ERC-20 on chains with no native gas token. See `nativeToken()`.
    address nativeToken;
    address cctpSrcPeriphery;
    address cctpTokenMessenger;
    uint32 cctpSourceDomain;
    /// @dev Single-token OFT periphery (USDT0). The OFT leaf picks the periphery by its getter selector, so
    ///      another OFT token is a beacon upgrade adding another getter.
    address oftSrcPeriphery;
    uint32 oftSrcEid;
    address usdc;
    address usdt;
    /// @dev Per-(token, bridge) execution-fee caps, in input-token units. A leaf names which to enforce via
    ///      a `bytes4` selector (its `maxExecutionFeeGetter`). Illustrative set — add more as routes need them.
    ///      For SpokePool this is the fixed component of the fee cap (added to the leaf's `maxFeeBps` term).
    uint256 usdcCctpMaxExecutionFee;
    /// @dev Cap on the submitter-chosen Circle fast-transfer fee (vanilla CCTP route), in bps of the
    ///      burned amount (0 ⇒ standard transfers only).
    uint256 usdcCctpMaxFeeBps;
    uint256 usdtOftMaxExecutionFee;
    uint256 usdcSpokePoolMaxExecutionFee;
    uint256 usdtSpokePoolMaxExecutionFee;
    uint256 wethSpokePoolMaxExecutionFee;
}

/**
 * @title CounterfactualBeacon
 * @notice The **configuration** of the per-chain counterfactual registry/beacon: every chain-specific value
 *         (bridge endpoints, domains/EIDs, fee signer, token addresses, fee caps) as a `public immutable`,
 *         named getter. All logic — root/implementation management, UUPS, ownership — lives in
 *         `CounterfactualBeaconBase`.
 * @dev The config is `public immutable` (in code, readable through the proxy under delegatecall), so changing
 *      a value or adding a token/cap means deploying a new implementation and `upgradeToAndCall`-ing to it.
 *      For an identical proxy address across chains, deploy against a uniform bootstrap then upgrade to the
 *      chain-specific implementation.
 *
 *      NOTE: these `immutable` values are **pure configuration**. A new implementation that changes only
 *      them (this contract's constructor wiring, with no change to `CounterfactualBeaconBase`) is a
 *      configuration change and is **not subject to audit** — only changes to the base's *logic* are audited.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualBeacon is CounterfactualBeaconBase {
    /// @inheritdoc ICounterfactualBeacon
    address public immutable signer;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable spokePool;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable wrappedNativeToken;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable nativeToken;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable cctpSrcPeriphery;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable cctpTokenMessenger;
    /// @inheritdoc ICounterfactualBeacon
    uint32 public immutable cctpSourceDomain;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable oftSrcPeriphery;
    /// @inheritdoc ICounterfactualBeacon
    uint32 public immutable oftSrcEid;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable usdc;
    /// @inheritdoc ICounterfactualBeacon
    address public immutable usdt;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcCctpMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcCctpMaxFeeBps;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdtOftMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdcSpokePoolMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable usdtSpokePoolMaxExecutionFee;
    /// @inheritdoc ICounterfactualBeacon
    uint256 public immutable wethSpokePoolMaxExecutionFee;

    /// @param config The chain-specific configuration baked into this implementation (see
    ///        `CounterfactualChainConfig`). Each field becomes an immutable, named getter.
    constructor(CounterfactualChainConfig memory config) {
        signer = config.signer;
        spokePool = config.spokePool;
        wrappedNativeToken = config.wrappedNativeToken;
        nativeToken = config.nativeToken;
        cctpSrcPeriphery = config.cctpSrcPeriphery;
        cctpTokenMessenger = config.cctpTokenMessenger;
        cctpSourceDomain = config.cctpSourceDomain;
        oftSrcPeriphery = config.oftSrcPeriphery;
        oftSrcEid = config.oftSrcEid;
        usdc = config.usdc;
        usdt = config.usdt;
        usdcCctpMaxExecutionFee = config.usdcCctpMaxExecutionFee;
        usdcCctpMaxFeeBps = config.usdcCctpMaxFeeBps;
        usdtOftMaxExecutionFee = config.usdtOftMaxExecutionFee;
        usdcSpokePoolMaxExecutionFee = config.usdcSpokePoolMaxExecutionFee;
        usdtSpokePoolMaxExecutionFee = config.usdtSpokePoolMaxExecutionFee;
        wethSpokePoolMaxExecutionFee = config.wethSpokePoolMaxExecutionFee;
        _disableInitializers();
    }
}
