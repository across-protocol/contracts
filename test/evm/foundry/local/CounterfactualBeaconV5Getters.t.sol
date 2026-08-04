// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import { CounterfactualChainConfig } from "../../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";

/**
 * @notice Covers the beacon's V5 getter set: the config round-trip through the constructor's immutables, and
 *         `stablePrice(address)` — the one piece of logic in an otherwise configuration-only contract.
 * @dev V5 routes resolve these by getter SELECTOR, so a renamed getter silently orphans every route committed
 *      against it. These assertions therefore pin the names as much as the values.
 */
contract CounterfactualBeaconV5GettersTest is CounterfactualTestBase {
    function setUp() public {
        _setUpCore();
    }

    /// @dev Every V5 field baked by the constructor is readable through its named getter.
    function testV5ConfigRoundTrips() public {
        CounterfactualChainConfig memory cfg = _v5Config();
        _deployBeacon(cfg);

        assertEq(beacon.gateway(), cfg.gateway, "gateway");
        assertEq(beacon.usdtOft(), cfg.usdtOft, "usdtOft");
        assertEq(beacon.spokePoolDepositExecutor(), cfg.spokePoolDepositExecutor, "spokePoolDepositExecutor");
        assertEq(beacon.cctpDepositExecutor(), cfg.cctpDepositExecutor, "cctpDepositExecutor");
        assertEq(beacon.oftDepositExecutor(), cfg.oftDepositExecutor, "oftDepositExecutor");
        assertEq(beacon.sameChainExecutor(), cfg.sameChainExecutor, "sameChainExecutor");
        assertEq(beacon.destinationExecutor(), cfg.destinationExecutor, "destinationExecutor");

        assertEq(beacon.usdtCctpMaxExecutionFee(), cfg.usdtCctpMaxExecutionFee, "usdtCctpMaxExecutionFee");
        assertEq(beacon.wethCctpMaxExecutionFee(), cfg.wethCctpMaxExecutionFee, "wethCctpMaxExecutionFee");
        assertEq(beacon.usdceCctpMaxExecutionFee(), cfg.usdceCctpMaxExecutionFee, "usdceCctpMaxExecutionFee");
        assertEq(beacon.usdcOftMaxExecutionFee(), cfg.usdcOftMaxExecutionFee, "usdcOftMaxExecutionFee");
        assertEq(beacon.wethOftMaxExecutionFee(), cfg.wethOftMaxExecutionFee, "wethOftMaxExecutionFee");
        assertEq(beacon.usdceOftMaxExecutionFee(), cfg.usdceOftMaxExecutionFee, "usdceOftMaxExecutionFee");
        assertEq(beacon.usdcSameChainMaxExecutionFee(), cfg.usdcSameChainMaxExecutionFee, "usdcSameChain");
        assertEq(beacon.usdtSameChainMaxExecutionFee(), cfg.usdtSameChainMaxExecutionFee, "usdtSameChain");
        assertEq(beacon.wethSameChainMaxExecutionFee(), cfg.wethSameChainMaxExecutionFee, "wethSameChain");
        assertEq(beacon.usdceSameChainMaxExecutionFee(), cfg.usdceSameChainMaxExecutionFee, "usdceSameChain");

        assertEq(beacon.usdcStablePrice(), cfg.usdcStablePrice, "usdcStablePrice");
        assertEq(beacon.usdtStablePrice(), cfg.usdtStablePrice, "usdtStablePrice");
        assertEq(beacon.wethStablePrice(), cfg.wethStablePrice, "wethStablePrice");
        assertEq(beacon.usdceStablePrice(), cfg.usdceStablePrice, "usdceStablePrice");
    }

    /// @dev An unset V5 field reads as zero — fail-closed for addresses, "fee-free"/"unpriced" for uints.
    function testUnsetV5ConfigReadsZero() public {
        _deployBeacon(_baseConfig());

        assertEq(beacon.gateway(), address(0), "gateway");
        assertEq(beacon.destinationExecutor(), address(0), "destinationExecutor");
        assertEq(beacon.usdcSameChainMaxExecutionFee(), 0, "usdcSameChainMaxExecutionFee");
        assertEq(beacon.usdcStablePrice(), 0, "usdcStablePrice");
    }

    /// @dev `stablePrice` dispatches over the configured token addresses, one price per token.
    function testStablePriceDispatchesPerToken() public {
        CounterfactualChainConfig memory cfg = _v5Config();
        _deployBeacon(cfg);

        assertEq(beacon.stablePrice(cfg.usdc), cfg.usdcStablePrice, "usdc");
        assertEq(beacon.stablePrice(cfg.usdt), cfg.usdtStablePrice, "usdt");
        assertEq(beacon.stablePrice(cfg.usdce), cfg.usdceStablePrice, "usdce");
        // WETH is configured but deliberately unpriced (volatile): V5 skips the stable floor for its pairs.
        assertEq(beacon.stablePrice(cfg.weth), 0, "weth is unpriced");
    }

    /// @dev A token the beacon does not carry is unpriced, and so is `address(0)` — which must NOT alias an
    ///      unconfigured token slot into that slot's price.
    function testStablePriceUnknownAndZeroTokenAreUnpriced() public {
        CounterfactualChainConfig memory cfg = _v5Config();
        cfg.usdce = address(0); // no USDC.e on this chain, but its price is still set below
        cfg.usdceStablePrice = 1e18;
        _deployBeacon(cfg);

        assertEq(beacon.stablePrice(makeAddr("wbtc")), 0, "unknown token");
        assertEq(beacon.stablePrice(address(0)), 0, "zero token must not resolve the empty usdce slot");
    }

    /// @dev A config with the full V5 surface populated with distinct, recognisable values.
    function _v5Config() internal returns (CounterfactualChainConfig memory cfg) {
        cfg = _baseConfig();
        // `spokePool` is not required by the beacon itself (the deploy scripts enforce it), but set it so the
        // config reads like a real one.
        cfg.spokePool = makeAddr("spokePool");
        cfg.usdc = makeAddr("usdc");
        cfg.usdt = makeAddr("usdt");
        cfg.weth = makeAddr("weth");
        cfg.usdce = makeAddr("usdce");

        cfg.gateway = makeAddr("gateway");
        cfg.usdtOft = makeAddr("usdtOft");
        cfg.spokePoolDepositExecutor = makeAddr("spokePoolDepositExecutor");
        cfg.cctpDepositExecutor = makeAddr("cctpDepositExecutor");
        cfg.oftDepositExecutor = makeAddr("oftDepositExecutor");
        cfg.sameChainExecutor = makeAddr("sameChainExecutor");
        cfg.destinationExecutor = makeAddr("destinationExecutor");

        cfg.usdtCctpMaxExecutionFee = 1;
        cfg.wethCctpMaxExecutionFee = 2;
        cfg.usdceCctpMaxExecutionFee = 3;
        cfg.usdcOftMaxExecutionFee = 4;
        cfg.wethOftMaxExecutionFee = 5;
        cfg.usdceOftMaxExecutionFee = 6;
        cfg.usdcSameChainMaxExecutionFee = 7;
        cfg.usdtSameChainMaxExecutionFee = 8;
        cfg.wethSameChainMaxExecutionFee = 9;
        cfg.usdceSameChainMaxExecutionFee = 10;

        // 1e18-fixed USD prices; WETH left at 0 (unpriced/volatile), as in the V5 test config.
        cfg.usdcStablePrice = 1e18;
        cfg.usdtStablePrice = 0.999e18;
        cfg.usdceStablePrice = 0.998e18;
        cfg.wethStablePrice = 0;
    }
}
