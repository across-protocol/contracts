// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Constants } from "../utils/Constants.sol";
import { DeployedAddresses } from "../utils/DeployedAddresses.sol";

/**
 * @title TestChainAdapter
 * @notice Foundry script to test a chain adapter by bridging tokens from L1 to L2
 * @dev Equivalent to the Hardhat task `testChainAdapter`
 *
 * Requires MNEMONIC to be set in .env file.
 *
 * Usage:
 *   forge script script/tasks/TestChainAdapter.s.sol:TestChainAdapter \
 *     --sig "run(uint256,address,address,uint256,address)" \
 *     <spokeChainId> <adapterAddress> <l1Token> <amount> <l2Token> \
 *     --rpc-url mainnet --broadcast
 *
 * Example (bridge 1 USDC to Optimism):
 *   forge script script/tasks/TestChainAdapter.s.sol:TestChainAdapter \
 *     --sig "run(uint256,address,address,uint256,address)" \
 *     10 0x... 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 1000000 0x... \
 *     --rpc-url mainnet --broadcast
 */
contract TestChainAdapter is Script, Constants, DeployedAddresses {
    function run(
        uint256 spokeChainId,
        address adapterAddress,
        address l1Token,
        uint256 amount,
        address l2Token
    ) external {
        uint256 hubChainId = block.chainid;
        require(hubChainId == 1 || hubChainId == 11155111, "Must run on mainnet (1) or sepolia (11155111)");

        // Derive signer from mnemonic in .env
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 privateKey = vm.deriveKey(mnemonic, 0);
        address sender = vm.addr(privateKey);

        console.log("");
        console.log("=============== Test Chain Adapter ===============");
        console.log("Hub Chain ID:", hubChainId);
        console.log("Spoke Chain ID:", spokeChainId);
        console.log("Adapter:", adapterAddress);
        console.log("L1 Token:", l1Token);
        console.log("L2 Token:", l2Token);
        console.log("Amount:", amount);
        console.log("Sender/Recipient:", sender);
        console.log("--------------------------------------------------");

        IERC20 token = IERC20(l1Token);
        uint256 adapterBalance = token.balanceOf(adapterAddress);

        console.log("Adapter token balance:", adapterBalance);

        vm.startBroadcast(privateKey);

        // If adapter doesn't have enough tokens, transfer them
        if (adapterBalance < amount) {
            uint256 needed = amount - adapterBalance;
            console.log("Transferring tokens to adapter:", needed);

            // Note: This transfer comes from the broadcasting wallet (the signer)
            // The signer must have approved or have sufficient balance
            bool success = token.transfer(adapterAddress, needed);
            require(success, "Token transfer failed");
            console.log("Transfer complete");

            // Re-check balance after transfer is confirmed
            adapterBalance = token.balanceOf(adapterAddress);
            console.log("Adapter balance after transfer:", adapterBalance);
        }

        // Call relayTokens on the adapter
        console.log("Calling relayTokens...");
        IAdapter(adapterAddress).relayTokens(l1Token, l2Token, adapterBalance, sender);

        console.log("--------------------------------------------------");
        console.log("[SUCCESS] Tokens relayed to chain", spokeChainId);
        console.log("=================================================");

        vm.stopBroadcast();
    }

    /// @notice Simplified version that looks up adapter from deployed addresses
    function runWithLookup(
        uint256 spokeChainId,
        string calldata adapterName,
        address l1Token,
        uint256 amount,
        address l2Token
    ) external {
        uint256 hubChainId = block.chainid;

        // Try to get adapter from deployed addresses
        address adapterAddress = getAddress(hubChainId, adapterName);
        require(adapterAddress != address(0), string.concat("Adapter not found: ", adapterName));

        this.run(spokeChainId, adapterAddress, l1Token, amount, l2Token);
    }
}

/// @notice Minimal interface for chain adapter
interface IAdapter {
    function relayTokens(address l1Token, address l2Token, uint256 amount, address to) external payable;
}
