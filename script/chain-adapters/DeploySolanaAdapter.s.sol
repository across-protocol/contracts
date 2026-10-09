// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Solana_Adapter } from "../../contracts/chain-adapters/Solana_Adapter.sol";
import { Constants } from "../utils/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { IMessageTransmitterV2, ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

// Mainnet only: no compatible V5 Spoke/Gateway deployment is configured on Solana devnet.
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/chain-adapters/DeploySolanaAdapter.s.sol:DeploySolanaAdapter --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/chain-adapters/DeploySolanaAdapter.s.sol:DeploySolanaAdapter --rpc-url $NODE_URL_1 --broadcast --verify -vvvv

contract DeploySolanaAdapter is Script, Test, Constants {
    // Solana mainnet addresses decoded from Base58 to bytes32.
    // The vault is the USDC ATA of the spoke state PDA (seed 0).
    // svm_spoke DLv3NggMiSaef97YCkew5xKUHDh13tVGZ7tydt3ZeAru
    bytes32 constant SOLANA_MAINNET_SPOKE_POOL = 0xb7664086de37ee70821c10445b162f2c7ec8795bd0800c1462949e2328d1dd5a;
    // USDC mint EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v
    bytes32 constant SOLANA_MAINNET_USDC = 0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61;
    // Vault HYhZwefNFmEm9sXYKkNM4QPMgGQnS9VjC6kgxwrGk3Ru
    bytes32 constant SOLANA_MAINNET_SPOKE_POOL_USDC_VAULT =
        0xf5d9ddc2b5d994277e15ea380117a3f8ef04ce1e37e2c678c3be4d11b2a5d034;

    function run() external {
        uint256 chainId = block.chainid;
        require(
            chainId == getChainId("MAINNET"),
            "Solana_Adapter deployment is mainnet only: no compatible Solana devnet Spoke/Gateway is configured"
        );

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        address usdc = getUSDCAddress(chainId);
        address cctpV2TokenMessenger = getL1Addresses(chainId).cctpV2TokenMessenger;
        address cctpV2MessageTransmitter = getL1Addresses(chainId).cctpV2MessageTransmitter;

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Solana_Adapter with constructor parameters
        Solana_Adapter solanaAdapter = new Solana_Adapter(
            IERC20(usdc), // L1 USDC
            ITokenMessenger(cctpV2TokenMessenger), // CCTP V2 Token Messenger
            IMessageTransmitterV2(cctpV2MessageTransmitter), // CCTP V2 Message Transmitter
            SOLANA_MAINNET_SPOKE_POOL,
            SOLANA_MAINNET_USDC,
            SOLANA_MAINNET_SPOKE_POOL_USDC_VAULT
        );

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Solana_Adapter deployed to:", address(solanaAdapter));
        console.log("L1 USDC:", usdc);
        console.log("CCTP V2 Token Messenger:", cctpV2TokenMessenger);
        console.log("CCTP V2 Message Transmitter:", cctpV2MessageTransmitter);
        console.log("Solana spoke pool:", vm.toString(SOLANA_MAINNET_SPOKE_POOL));
        console.log("Solana USDC:", vm.toString(SOLANA_MAINNET_USDC));
        console.log("Solana spoke pool USDC vault:", vm.toString(SOLANA_MAINNET_SPOKE_POOL_USDC_VAULT));

        vm.stopBroadcast();
    }
}
