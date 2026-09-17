// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Solana_Adapter } from "../../contracts/chain-adapters/Solana_Adapter.sol";
import { Constants } from "../utils/Constants.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { IMessageTransmitterV2, ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x" entries
// 2. forge script script/chain-adapters/DeploySolanaAdapter.s.sol:DeploySolanaAdapter --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy on mainnet by adding --broadcast --verify flags.
// 5. forge script script/chain-adapters/DeploySolanaAdapter.s.sol:DeploySolanaAdapter --rpc-url $NODE_URL_1 --broadcast --verify -vvvv
// Optional: set CCTP_MIN_FINALITY_THRESHOLD to override the default finalized (2000) CCTP V2 threshold. The Solana
// spoke pool only accepts finalized messages, so lower it only if Circle redefines its threshold values.

contract DeploySolanaAdapter is Script, Test, Constants {
    // Solana addresses decoded from Base58 to bytes32. Ethereum mainnet pairs with Solana mainnet and Sepolia with
    // Solana devnet in CCTP. The vault is the USDC ATA of the spoke state PDA (seed 0).
    // svm_spoke DLv3NggMiSaef97YCkew5xKUHDh13tVGZ7tydt3ZeAru
    bytes32 constant SOLANA_MAINNET_SPOKE_POOL = 0xb7664086de37ee70821c10445b162f2c7ec8795bd0800c1462949e2328d1dd5a;
    // USDC mint EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v
    bytes32 constant SOLANA_MAINNET_USDC = 0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61;
    // Vault HYhZwefNFmEm9sXYKkNM4QPMgGQnS9VjC6kgxwrGk3Ru
    bytes32 constant SOLANA_MAINNET_SPOKE_POOL_USDC_VAULT =
        0xf5d9ddc2b5d994277e15ea380117a3f8ef04ce1e37e2c678c3be4d11b2a5d034;
    // svm_spoke JAZWcGrpSWNPTBj8QtJ9UyQqhJCDhG9GJkDeMf5NQBiq
    bytes32 constant SOLANA_DEVNET_SPOKE_POOL = 0xff09aa2d3eb1bc9da19e82264930e13d3993e1160f3039ef21afd1565376efca;
    // USDC mint 4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU
    bytes32 constant SOLANA_DEVNET_USDC = 0x3b442cb3912157f13a933d0134282d032b5ffecd01a2dbf1b7790608df002ea7;
    // Vault BoYRcMVZE7aBdWkMiCXn1Choa1EAAsi4PR2PmzrKeErJ
    bytes32 constant SOLANA_DEVNET_SPOKE_POOL_USDC_VAULT =
        0xa0811e38b883d8ff83f742a12d41a6431acd580a662153d5d2146db0e0ed0ec7;

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get the current chain ID
        uint256 chainId = block.chainid;

        // Verify this is being deployed on Ethereum mainnet or Sepolia
        bool isMainnet = chainId == getChainId("MAINNET");
        require(
            isMainnet || chainId == getChainId("SEPOLIA"),
            "Solana_Adapter should only be deployed on Ethereum mainnet or Sepolia"
        );

        (bytes32 solanaSpokePool, bytes32 solanaUsdc, bytes32 solanaSpokePoolUsdcVault) = isMainnet
            ? (SOLANA_MAINNET_SPOKE_POOL, SOLANA_MAINNET_USDC, SOLANA_MAINNET_SPOKE_POOL_USDC_VAULT)
            : (SOLANA_DEVNET_SPOKE_POOL, SOLANA_DEVNET_USDC, SOLANA_DEVNET_SPOKE_POOL_USDC_VAULT);
        uint32 cctpMinFinalityThreshold = uint32(
            vm.envOr("CCTP_MIN_FINALITY_THRESHOLD", uint256(CCTP_FINALITY_THRESHOLD_FINALIZED))
        );

        address usdc = getUSDCAddress(chainId);
        address cctpV2TokenMessenger = getL1Addresses(chainId).cctpV2TokenMessenger;
        address cctpV2MessageTransmitter = getL1Addresses(chainId).cctpV2MessageTransmitter;

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Solana_Adapter with constructor parameters
        Solana_Adapter solanaAdapter = new Solana_Adapter(
            IERC20(usdc), // L1 USDC
            ITokenMessenger(cctpV2TokenMessenger), // CCTP V2 Token Messenger
            IMessageTransmitterV2(cctpV2MessageTransmitter), // CCTP V2 Message Transmitter
            solanaSpokePool,
            solanaUsdc,
            solanaSpokePoolUsdcVault,
            cctpMinFinalityThreshold
        );

        // Log the deployed addresses
        console.log("Chain ID:", chainId);
        console.log("Solana_Adapter deployed to:", address(solanaAdapter));
        console.log("L1 USDC:", usdc);
        console.log("CCTP V2 Token Messenger:", cctpV2TokenMessenger);
        console.log("CCTP V2 Message Transmitter:", cctpV2MessageTransmitter);
        console.log("CCTP min finality threshold:", cctpMinFinalityThreshold);
        console.log("Solana spoke pool:", vm.toString(solanaSpokePool));
        console.log("Solana USDC:", vm.toString(solanaUsdc));
        console.log("Solana spoke pool USDC vault:", vm.toString(solanaSpokePoolUsdcVault));

        vm.stopBroadcast();
    }
}
