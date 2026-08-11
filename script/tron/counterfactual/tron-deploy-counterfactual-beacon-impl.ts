#!/usr/bin/env ts-node
/**
 * Deploys the chain-specific CounterfactualBeacon IMPLEMENTATION to Tron, baking the chain's
 * CounterfactualChainConfig into its immutables.
 *
 * This is the Tron counterpart of script/counterfactual/DeployCounterfactualBeaconImpl.s.sol —
 * Foundry cannot broadcast to Tron, so the config resolution performed by
 * CounterfactualConfig._buildChainConfig() is mirrored here in TypeScript, from the same sources:
 *   - script/counterfactual/config.toml          (signer, per-token max-execution-fee caps, CCTP bps cap)
 *   - generated/constants.json                   (tokens, wrapped native, CCTP domain / OFT EID, messenger)
 *   - broadcast/deployed-addresses.json          (SpokePool, sponsored bridge peripheries)
 * Tron entries in those files are Base58Check (T...); they are converted to EVM hex here. Keep the
 * resolution semantics in sync with CounterfactualConfig.sol when they change.
 *
 * Next: run tron-deploy-counterfactual-beacon to deploy the proxy/dispatcher stack over this impl.
 * After a config change the impl is immutable — deploy a new impl, then the owner upgrades the proxy
 * out of band (`upgradeToAndCall(newImpl, "")`).
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *   --dry-run  — print the resolved CounterfactualChainConfig and exit without deploying
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-beacon-impl [--testnet] [--dry-run]
 */

import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import * as toml from "toml";
import { TronWeb } from "tronweb";
import { deployContract, encodeArgs, tronToEvmAddress, resolveChainId } from "../deploy";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
/// Mirrors CounterfactualConfig.NATIVE_SENTINEL / CounterfactualDepositSpokePool.NATIVE_SENTINEL.
const NATIVE_SENTINEL = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

const REPO_ROOT = path.resolve(__dirname, "../../..");
const CONFIG_TOML = path.join(REPO_ROOT, "script/counterfactual/config.toml");
const CONSTANTS_JSON = path.join(REPO_ROOT, "generated/constants.json");
const DEPLOYED_ADDRESSES_JSON = path.join(REPO_ROOT, "broadcast/deployed-addresses.json");

function fail(msg: string): never {
  console.log(`Error: ${msg}`);
  process.exit(1);
}

/** Normalize an address that may be Tron Base58Check (T...) or EVM hex (0x...) to EVM hex. */
function toEvmHex(value: string, name: string): string {
  if (/^0x[0-9a-fA-F]{40}$/.test(value)) return value;
  if (TronWeb.isAddress(value)) return tronToEvmAddress(value);
  return fail(`${name}: "${value}" is neither an EVM hex address nor a Tron Base58Check address`);
}

/** Read a JSON path like ["USDT", "728126428"]; returns undefined when absent. */
function dig(obj: any, keys: string[]): any {
  return keys.reduce((o, k) => (o == null ? undefined : o[k]), obj);
}

/** Resolve an optional address from a JSON doc: absent → zero address (route not configured). */
function resolveAddress(doc: any, keys: string[], name: string): string {
  const v = dig(doc, keys);
  return v == null ? ZERO_ADDRESS : toEvmHex(v, name);
}

/** Config.toml uint (fee caps are raw onchain amounts; Tron's all fit in a JS number, but check). */
function tomlUint(section: any, key: string): number | undefined {
  const v = section?.uint?.[key];
  if (v == null) return undefined;
  if (!Number.isSafeInteger(v) || v < 0) fail(`config.toml ${key}: ${v} is not a safe non-negative integer`);
  return v;
}

/** Mirrors CounterfactualConfig._optionalAddress: absent (or explicitly zero) -> zero address. Used for the
 *  V5 stack, which has no on-chain source to resolve from. Across V5 does not target Tron, so these are
 *  expected to be unset here — but they are read, not hardcoded, so a filled entry would be honoured. */
function optionalAddress(section: any, key: string): string {
  const v = section?.address?.[key];
  return v == null ? ZERO_ADDRESS : toEvmHex(v, key);
}

/** Mirrors CounterfactualConfig._stablePrice: a chain-invariant 1e18-fixed USD price from the `[0.uint]`
 *  globals, baked only where the token itself resolves. Zero = unpriced (the stable floor is skipped). */
function stablePrice(config: any, key: string, token: string): string {
  if (token === ZERO_ADDRESS) return "0";
  const v = config?.["0"]?.uint?.[key];
  return v == null ? "0" : String(v);
}

/** Mirrors CounterfactualConfig._maxExecutionFee: 0 when the token is unset on this chain; the config
 *  value must exist and be nonzero when the token is set (a zero cap would make all nonzero fees revert). */
function maxExecutionFee(section: any, key: string, token: string): number {
  if (token === ZERO_ADDRESS) return 0;
  const fee = tomlUint(section, key);
  if (fee == null) fail(`config.toml: ${key} not configured for this chain`);
  if (fee === 0) fail(`config.toml: ${key} is zero but its token is configured on this chain`);
  return fee;
}

/** Mirrors CounterfactualConfig._buildChainConfig for a Tron chain. Returns the 20 fields of
 *  CounterfactualChainConfig in struct order. */
function buildChainConfig(chainId: string): { types: string[]; values: (string | number)[] } {
  const config = toml.parse(fs.readFileSync(CONFIG_TOML, "utf-8"));
  const constants = JSON.parse(fs.readFileSync(CONSTANTS_JSON, "utf-8"));
  const deployed = JSON.parse(fs.readFileSync(DEPLOYED_ADDRESSES_JSON, "utf-8"));

  const section = config[chainId] ?? fail(`config.toml: no [${chainId}] section`);
  const contracts = dig(deployed, ["chains", chainId, "contracts"]) ?? {};

  const signerRaw = section.address?.signer ?? fail(`config.toml: no signer in [${chainId}.address]`);
  const signer = toEvmHex(signerRaw, "signer");
  if (signer === ZERO_ADDRESS) fail("config: signer is zero");

  const deployedAddress = (name: string) =>
    contracts[name]?.address ? toEvmHex(contracts[name].address, name) : ZERO_ADDRESS;

  const spokePool = deployedAddress("SpokePool");
  const wrappedNativeToken = resolveAddress(constants, ["WRAPPED_NATIVE_TOKENS", chainId], "wrappedNativeToken");
  // NATIVE_TOKEN override forces an ERC-20; otherwise the msg.value-wrap sentinel (meaningless without
  // a wrapped native token, so fall back to zero → the leaf cleanly RouteNotConfigured's).
  const nativeTokenOverride = dig(constants, ["NATIVE_TOKEN", chainId]);
  const nativeToken = nativeTokenOverride
    ? toEvmHex(nativeTokenOverride, "nativeToken")
    : wrappedNativeToken === ZERO_ADDRESS
      ? ZERO_ADDRESS
      : NATIVE_SENTINEL;
  // Both deployed-addresses.json casings, like CounterfactualConfig._resolveCctpPeriphery.
  const cctpSrcPeriphery =
    deployedAddress("SponsoredCCTPSrcPeriphery") !== ZERO_ADDRESS
      ? deployedAddress("SponsoredCCTPSrcPeriphery")
      : deployedAddress("SponsoredCctpSrcPeriphery");
  const cctpDomain = dig(constants, ["PUBLIC_NETWORKS", chainId, "cctpDomain"]);
  const cctpSourceDomain = cctpDomain != null && cctpDomain !== -1 ? cctpDomain : 0;
  const cctpTokenMessenger =
    resolveAddress(constants, ["L2_ADDRESS_MAP", chainId, "cctpV2TokenMessenger"], "cctpTokenMessenger") !==
    ZERO_ADDRESS
      ? resolveAddress(constants, ["L2_ADDRESS_MAP", chainId, "cctpV2TokenMessenger"], "cctpTokenMessenger")
      : resolveAddress(constants, ["L1_ADDRESS_MAP", chainId, "cctpV2TokenMessenger"], "cctpTokenMessenger");
  const oftSrcPeriphery = deployedAddress("SponsoredOFTSrcPeriphery");
  const oftEid = dig(constants, ["PUBLIC_NETWORKS", chainId, "oftEid"]);
  const oftSrcEid = oftEid != null && oftEid !== -1 ? oftEid : 0;
  // Native USDC and bridged USDC.e are separate tokens — mirrors CounterfactualConfig._resolveUsdc /
  // _resolveUsdce. USDC.e only counts where distinct from native USDC (mainnet's entry aliases it).
  const usdc = resolveAddress(constants, ["USDC", chainId], "usdc");
  const usdceRaw = resolveAddress(constants, ["USDCe", chainId], "usdce");
  const usdce = usdceRaw === usdc ? ZERO_ADDRESS : usdceRaw;
  const usdt = resolveAddress(constants, ["USDT", chainId], "usdt");
  const wbtc = resolveAddress(constants, ["WBTC", chainId], "wbtc");
  const weth = resolveAddress(constants, ["WETH", chainId], "weth");
  const pathUsd = resolveAddress(constants, ["pathUSD", chainId], "pathUsd");
  const usdg = resolveAddress(constants, ["USDG", chainId], "usdg");

  const usdcMaxExecutionFee = maxExecutionFee(section, "usdcMaxExecutionFee", usdc);
  const usdceMaxExecutionFee = maxExecutionFee(section, "usdceMaxExecutionFee", usdce);
  const usdtMaxExecutionFee = maxExecutionFee(section, "usdtMaxExecutionFee", usdt);
  const wethMaxExecutionFee = maxExecutionFee(section, "wethMaxExecutionFee", weth);
  const wbtcMaxExecutionFee = maxExecutionFee(section, "wbtcMaxExecutionFee", wbtc);
  const pathUsdMaxExecutionFee = maxExecutionFee(section, "pathUsdMaxExecutionFee", pathUsd);
  const usdgMaxExecutionFee = maxExecutionFee(section, "usdgMaxExecutionFee", usdg);
  // Bps cap on the submitter-chosen Circle fast-transfer fee — per-chain ([N.uint] section); zero is
  // valid (0 ⇒ standard transfers only), unlike the maxExecutionFee caps.
  const usdcCctpMaxFeeBps =
    tomlUint(section, "usdcCctpMaxFeeBps") ?? fail("config.toml: usdcCctpMaxFeeBps not configured for this chain");

  // Same deploy guards as CounterfactualConfig._buildChainConfig.
  if (spokePool === ZERO_ADDRESS)
    fail("config: SpokePool must be deployed on this chain (add to deployed-addresses.json)");
  if (usdt === ZERO_ADDRESS) fail(`config: USDT must be configured for Tron (add .USDT.${chainId} to constants.json)`);
  if (nativeToken === NATIVE_SENTINEL && wrappedNativeToken === ZERO_ADDRESS)
    fail("config: nativeToken=sentinel requires wrappedNativeToken");

  // Declared-support assertions — mirrors CounterfactualConfig._validateDeclaredSupport. Every
  // [<chainId>.bool] flag must match resolved reality, in both directions; missing flags fail too.
  const hasCctp = cctpDomain != null && cctpDomain !== -1;
  const hasOft = oftEid != null && oftEid !== -1;
  const actuals: Record<string, boolean> = {
    usdc: usdc !== ZERO_ADDRESS,
    usdce: usdce !== ZERO_ADDRESS,
    usdt: usdt !== ZERO_ADDRESS,
    wbtc: wbtc !== ZERO_ADDRESS,
    pathUsd: pathUsd !== ZERO_ADDRESS,
    usdg: usdg !== ZERO_ADDRESS,
    weth: weth !== ZERO_ADDRESS,
    spokePool: spokePool !== ZERO_ADDRESS,
    sponsoredCctp: hasCctp && cctpSrcPeriphery !== ZERO_ADDRESS,
    vanillaCctp: cctpTokenMessenger !== ZERO_ADDRESS,
    oft: hasOft && oftSrcPeriphery !== ZERO_ADDRESS,
  };
  for (const [key, actual] of Object.entries(actuals)) {
    const declared = section.bool?.[key];
    if (typeof declared !== "boolean") fail(`config: [${chainId}.bool] ${key} flag missing`);
    if (declared !== actual)
      fail(
        `config: ${key} declared ${declared} but constants/broadcasts resolve it as ${actual ? "supported" : "unsupported"}`
      );
  }

  // CounterfactualChainConfig, in struct field order. Every field is static, so encoding them flat
  // yields byte-identical calldata to abi.encode-ing the single struct tuple.
  return {
    types: [
      "address", // signer
      "address", // gateway
      "address", // usdc
      "address", // usdce
      "address", // usdt
      "address", // wbtc
      "address", // weth
      "address", // pathUsd
      "address", // usdg
      "address", // spokePool
      "address", // wrappedNativeToken
      "address", // nativeToken
      "address", // cctpSrcPeriphery
      "address", // cctpTokenMessenger
      "uint32", // cctpSourceDomain
      "address", // oftSrcPeriphery
      "uint32", // oftSrcEid
      "address", // usdtOft
      "address", // spokePoolDepositExecutor
      "address", // cctpDepositExecutor
      "address", // oftDepositExecutor
      "address", // sameChainExecutor
      "uint256", // usdcSpokePoolMaxExecutionFee
      "uint256", // usdceSpokePoolMaxExecutionFee
      "uint256", // usdtSpokePoolMaxExecutionFee
      "uint256", // wethSpokePoolMaxExecutionFee
      "uint256", // wbtcSpokePoolMaxExecutionFee
      "uint256", // pathUsdSpokePoolMaxExecutionFee
      "uint256", // usdgSpokePoolMaxExecutionFee
      "uint256", // usdcSameChainMaxExecutionFee
      "uint256", // usdceSameChainMaxExecutionFee
      "uint256", // usdtSameChainMaxExecutionFee
      "uint256", // wethSameChainMaxExecutionFee
      "uint256", // wbtcSameChainMaxExecutionFee
      "uint256", // pathUsdSameChainMaxExecutionFee
      "uint256", // usdgSameChainMaxExecutionFee
      "uint256", // usdcCctpMaxExecutionFee
      "uint256", // usdtOftMaxExecutionFee
      "uint256", // usdcCctpMaxFeeBps
      "uint256", // usdcStablePrice
      "uint256", // usdceStablePrice
      "uint256", // usdtStablePrice
      "uint256", // pathUsdStablePrice
      "uint256", // usdgStablePrice
      "uint256", // wethStablePrice
      "uint256", // wbtcStablePrice
    ],
    values: [
      signer, // signer
      optionalAddress(section, "gateway"), // gateway
      usdc, // usdc
      usdce, // usdce
      usdt, // usdt
      wbtc, // wbtc
      weth, // weth
      pathUsd, // pathUsd
      usdg, // usdg
      spokePool, // spokePool
      wrappedNativeToken, // wrappedNativeToken
      nativeToken, // nativeToken
      cctpSrcPeriphery, // cctpSrcPeriphery
      cctpTokenMessenger, // cctpTokenMessenger
      cctpSourceDomain, // cctpSourceDomain
      oftSrcPeriphery, // oftSrcPeriphery
      oftSrcEid, // oftSrcEid
      optionalAddress(section, "usdtOft"), // usdtOft
      optionalAddress(section, "spokePoolDepositExecutor"), // spokePoolDepositExecutor
      optionalAddress(section, "cctpDepositExecutor"), // cctpDepositExecutor
      optionalAddress(section, "oftDepositExecutor"), // oftDepositExecutor
      optionalAddress(section, "sameChainExecutor"), // sameChainExecutor
      usdcMaxExecutionFee, // usdcSpokePoolMaxExecutionFee
      usdceMaxExecutionFee, // usdceSpokePoolMaxExecutionFee
      usdtMaxExecutionFee, // usdtSpokePoolMaxExecutionFee
      wethMaxExecutionFee, // wethSpokePoolMaxExecutionFee
      wbtcMaxExecutionFee, // wbtcSpokePoolMaxExecutionFee
      pathUsdMaxExecutionFee, // pathUsdSpokePoolMaxExecutionFee
      usdgMaxExecutionFee, // usdgSpokePoolMaxExecutionFee
      usdcMaxExecutionFee, // usdcSameChainMaxExecutionFee
      usdceMaxExecutionFee, // usdceSameChainMaxExecutionFee
      usdtMaxExecutionFee, // usdtSameChainMaxExecutionFee
      wethMaxExecutionFee, // wethSameChainMaxExecutionFee
      wbtcMaxExecutionFee, // wbtcSameChainMaxExecutionFee
      pathUsdMaxExecutionFee, // pathUsdSameChainMaxExecutionFee
      usdgMaxExecutionFee, // usdgSameChainMaxExecutionFee
      usdcMaxExecutionFee, // usdcCctpMaxExecutionFee
      usdtMaxExecutionFee, // usdtOftMaxExecutionFee
      usdcCctpMaxFeeBps, // usdcCctpMaxFeeBps
      stablePrice(config, "usdcStablePrice", usdc), // usdcStablePrice
      stablePrice(config, "usdceStablePrice", usdce), // usdceStablePrice
      stablePrice(config, "usdtStablePrice", usdt), // usdtStablePrice
      stablePrice(config, "pathUsdStablePrice", pathUsd), // pathUsdStablePrice
      stablePrice(config, "usdgStablePrice", usdg), // usdgStablePrice
      stablePrice(config, "wethStablePrice", weth), // wethStablePrice
      stablePrice(config, "wbtcStablePrice", wbtc), // wbtcStablePrice
    ],
  };
}

async function main(): Promise<void> {
  const chainId = resolveChainId();

  console.log("=== CounterfactualBeacon implementation deployment ===");
  console.log(`Chain ID: ${chainId}`);

  const { types, values } = buildChainConfig(chainId);
  console.log("Resolved CounterfactualChainConfig:");
  types.forEach((t, i) => console.log(`  ${t.padEnd(8)} ${values[i]}`));

  if (process.argv.includes("--dry-run")) {
    console.log("--dry-run: skipping deployment.");
    return;
  }

  const encodedArgs = encodeArgs(types, values);
  const artifactPath = path.resolve(REPO_ROOT, "out-tron/CounterfactualBeacon.sol/CounterfactualBeacon.json");

  await deployContract({ chainId, artifactPath, encodedArgs });
  console.log("Next: run tron-deploy-counterfactual-beacon to deploy the proxy stack over this impl.");
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
