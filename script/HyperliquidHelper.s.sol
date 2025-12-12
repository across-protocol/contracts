// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { HyperliquidHelper } from "../contracts/handlers/HyperliquidHelper.sol";
import { HyperCoreLib } from "../contracts/libraries/HyperCoreLib.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

// How to run:
// forge script script/HyperliquidHelper.s.sol:TestHyperliquidHelper --rpc-url hyperevm -vvvv

contract TestHyperliquidHelper is Script, Test {
    using SafeERC20 for IERC20;

    function run() external {
        HyperliquidHelper hyperliquidHelper = HyperliquidHelper(0x023E46724359138E052772082D445897186E9350);
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        IERC20 usdc = IERC20(0xb88339CB7199b77E23DB6E890353E22632Ba630f);
        uint64 usdcTokenIndex = 0;
        uint32 usdt_usdc_SpotMarketIndex = 166;
        bool usdt_usdc_isBuy = true; // We are going to buy USDT with USDC
        uint128 cloid = uint128(block.timestamp);

        vm.startBroadcast(deployerPrivateKey);

        hyperliquidHelper.depositToHypercore(
            address(usdc),
            usdt_usdc_SpotMarketIndex,
            usdt_usdc_isBuy,
            1e6,
            100100000, // 1.001
            cloid,
            HyperCoreLib.Tif.GTC
        );

        // Logs
        console.log("Placed order with cloid:", cloid);

        vm.stopBroadcast();
    }
}
