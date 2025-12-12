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
// forge script script/DeployHyperliquidHelper.s.sol:DeployHyperliquidHelper --rpc-url hyperevm -vvvv

contract DeployHyperliquidHelper is Script, Test {
    using SafeERC20 for IERC20;

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        // Set up USDH as a supported token for this handler.
        IERC20 usdh = IERC20(0x111111a1a0667d36bD57c0A9f569b98057111111);
        uint64 usdhTokenIndex = 360;
        address usdhHypercoreSystemAddress = 0x2000000000000000000000000000000000000168;
        int8 usdhDecimalDiff = -2; // USDH has 2 extra decimals on Core compared to EVM.

        // Set up USDT as a supported token for this handler.
        IERC20 usdt = IERC20(0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb);
        uint64 usdtTokenIndex = 268;
        address usdtHypercoreSystemAddress = 0x200000000000000000000000000000000000010C;
        int8 usdtDecimalDiff = -2; // USDT has 2 extra decimals on Core compared to EVM.

        IERC20 usdc = IERC20(0xb88339CB7199b77E23DB6E890353E22632Ba630f);
        uint64 usdcTokenIndex = 0;
        address usdcHypercoreSystemAddress = 0x2000000000000000000000000000000000000000;
        int8 usdcDecimalDiff = -2; // USDC has 2 extra decimals on Core compared to EVM.

        address cctpCoreDepositWalletAddress = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;

        vm.startBroadcast(deployerPrivateKey);

        HyperliquidHelper hyperliquidHelper = new HyperliquidHelper(address(usdc), cctpCoreDepositWalletAddress);

        // Activate Handler account so it can write to CoreWriter by sending 1 core wei.
        HyperCoreLib.transferERC20CoreToCore(usdhTokenIndex, address(hyperliquidHelper), 1);
        hyperliquidHelper.addSupportedToken(address(usdh), usdhHypercoreSystemAddress, usdhTokenIndex, usdhDecimalDiff);
        hyperliquidHelper.addSupportedToken(address(usdt), usdtHypercoreSystemAddress, usdtTokenIndex, usdtDecimalDiff);
        hyperliquidHelper.addSupportedToken(address(usdc), usdcHypercoreSystemAddress, usdcTokenIndex, usdcDecimalDiff);

        usdh.forceApprove(address(hyperliquidHelper), type(uint256).max);
        usdt.forceApprove(address(hyperliquidHelper), type(uint256).max);
        usdc.forceApprove(address(hyperliquidHelper), type(uint256).max);

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("HyperliquidHelper deployed to:", address(hyperliquidHelper));
        console.log("USDH token index:", usdhTokenIndex);
        console.log("USDH hypercore system address:", usdhHypercoreSystemAddress);
        console.log("USDH decimal diff:", usdhDecimalDiff);
        console.log("USDT token index:", usdtTokenIndex);
        console.log("USDT hypercore system address:", usdtHypercoreSystemAddress);
        console.log("USDT decimal diff:", usdtDecimalDiff);
        console.log("USDC token index:", usdcTokenIndex);
        console.log("USDC hypercore system address:", usdcHypercoreSystemAddress);
        console.log("USDC decimal diff:", usdcDecimalDiff);

        vm.stopBroadcast();
    }
}
