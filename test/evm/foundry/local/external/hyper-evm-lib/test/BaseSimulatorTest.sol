// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { PrecompileLib } from "../src/PrecompileLib.sol";
import { CoreWriterLib } from "../src/CoreWriterLib.sol";
import { HLConversions } from "../src/common/HLConversions.sol";
import { HLConstants } from "../src/common/HLConstants.sol";
import { HyperCore } from "./simulation/HyperCore.sol";
import { CoreSimulatorLib } from "./simulation/CoreSimulatorLib.sol";

/**
 * @title BaseSimulatorTest
 * @notice Base test contract that sets up the HyperCore simulation
 */
abstract contract BaseSimulatorTest is Test {
    using PrecompileLib for address;
    using HLConversions for *;

    HyperCore public hyperCore;

    // Common token addresses
    address public constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address public constant uBTC = 0x9FDBdA0A5e284c32744D2f17Ee5c74B284993463;
    address public constant uETH = 0xBe6727B535545C67d5cAa73dEa54865B92CF7907;
    address public constant uSOL = 0x068f321Fa8Fb9f0D135f290Ef6a3e2813e1c8A29;

    // Common token indices
    uint64 public constant USDC_TOKEN = 0;
    uint64 public constant HYPE_TOKEN = 150;

    address user = makeAddr("user");

    function setUp() public virtual {
        string memory hyperliquidRpc = "https://rpc.hyperliquid.xyz/evm";
        vm.createSelectFork(hyperliquidRpc);

        hyperCore = CoreSimulatorLib.init();

        hyperCore.forceAccountActivation(user);
        hyperCore.forceSpot(user, USDC_TOKEN, 1000e8);
        hyperCore.forcePerpBalance(user, 1000e6);
    }
}
