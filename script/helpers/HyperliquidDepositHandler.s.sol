// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/HyperliquidDepositHandler.s.sol:FundHyperliquidDepositHandler --rpc-url hyperevm -vvvv
// 3. Execute on-chain by adding --broadcast flag.

interface IHyperliquidDepositHandler {
    function donationBox() external view returns (address);
    function depositToHypercore(address token, uint256 amount, address user, bytes memory signature) external;
}

contract FundHyperliquidDepositHandler is Script, Test {
    address constant DEPOSIT_HANDLER = 0x861E127036B28D32f3777B4676F6bbb9e007d195;
    address constant USDH = 0x111111a1a0667d36bD57c0A9f569b98057111111;

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        uint256 amount = vm.envOr("AMOUNT", uint256(1e6)); // Default: 1 USDH (6 decimals)

        IERC20 usdh = IERC20(USDH);
        IHyperliquidDepositHandler handler = IHyperliquidDepositHandler(DEPOSIT_HANDLER);
        address donationBox = handler.donationBox();

        console.log("Deposit Handler:", DEPOSIT_HANDLER);
        console.log("USDH:", USDH);
        console.log("Donation Box:", donationBox);
        console.log("Deployer:", deployer);
        console.log("Amount:", amount);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Approve USDH to the deposit handler for depositToHypercore.
        usdh.approve(DEPOSIT_HANDLER, amount);

        // Step 2: Fund the donation box with USDH for account activation fees.
        // The donation box accepts direct token transfers.
        usdh.transfer(donationBox, amount);

        // Step 3: Call depositToHypercore to bridge tokens from HyperEVM to Hypercore.
        // Note: signature must be provided by the Across API signer for the deployer address.
        bytes memory signature = vm.envOr("SIGNATURE", bytes(""));
        handler.depositToHypercore(USDH, amount, deployer, signature);

        console.log("Approved, funded donation box, and deposited to Hypercore");

        vm.stopBroadcast();
    }
}
