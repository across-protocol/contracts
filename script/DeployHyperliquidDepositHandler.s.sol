// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { HyperliquidDepositHandler } from "../contracts/handlers/HyperliquidDepositHandler.sol";
import { HyperCoreLib } from "../contracts/libraries/HyperCoreLib.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

// How to run:
// forge script script/DeployHyperliquidDepositHandler.s.sol:DeployHyperliquidDepositHandler --rpc-url hyperevm -vvvv

contract DeployHyperliquidDepositHandler is Script, Test {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        // Set the initial signer to the deployer's address.
        address signer = vm.addr(deployerPrivateKey);

        address spokePool = 0x35E63eA3eb0fb7A3bc543C71FB66412e1F6B0E04;

        // Get the current chain ID
        uint256 chainId = block.chainid;

        // Set up USDH as a supported token for this handler.
        IERC20 usdh = IERC20(0x111111a1a0667d36bD57c0A9f569b98057111111);
        uint64 usdhTokenIndex = 360;
        uint256 usdhActivationFee = 1000000; // 1 USDH
        int8 usdhDecimalDiff = -2; // USDH has 2 extra decimals on Core compared to EVM.

        vm.startBroadcast(deployerPrivateKey);

        HyperliquidDepositHandler hyperliquidDepositHandler = new HyperliquidDepositHandler(signer, spokePool);

        // Activate Handler account so it can write to CoreWriter by sending 1 core wei.
        HyperCoreLib.transferERC20CoreToCore(usdhTokenIndex, address(hyperliquidDepositHandler), 1);
        hyperliquidDepositHandler.addSupportedToken(address(usdh), usdhTokenIndex, 1000000, usdhDecimalDiff);

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("HyperliquidDepositHandler deployed to:", address(hyperliquidDepositHandler));
        console.log("Signer required to sign payloads for handleV3AcrossMessage:", signer);
        console.log("USDH token index:", usdhTokenIndex);
        console.log("USDH activation fee:", usdhActivationFee);
        console.log("USDH decimal diff:", usdhDecimalDiff);

        vm.stopBroadcast();
    }
}
