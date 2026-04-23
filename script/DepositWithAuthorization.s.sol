// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SpokePoolPeripheryInterface } from "../contracts/interfaces/SpokePoolPeripheryInterface.sol";
import { SponsoredCCTPInterface } from "../contracts/interfaces/SponsoredCCTPInterface.sol";
import { SponsoredCCTPSrcPeriphery } from "../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";
import { SponsoredExecutionModeInterface } from "../contracts/interfaces/SponsoredExecutionModeInterface.sol";
import { ArbitraryEVMFlowExecutor } from "../contracts/periphery/mintburn/ArbitraryEVMFlowExecutor.sol";
import { AccountCreationMode } from "../contracts/periphery/mintburn/Structs.sol";
import { MulticallHandler } from "../contracts/handlers/MulticallHandler.sol";
import { AddressToBytes32 } from "../contracts/libraries/AddressConverters.sol";
import { HyperCoreLib } from "../contracts/libraries/HyperCoreLib.sol";

/**
 * @notice Deposits via ERC-3009 authorization through:
 *   SpokePoolPeriphery.depositWithAuthorization() → TransferProxy → MulticallHandler → SponsoredCCTPSrcPeriphery.depositForBurn()
 *
 * @dev Flow:
 *   1. Sign CCTP quote (for SponsoredCCTPSrcPeriphery)
 *   2. Build MulticallHandler message (approve USDC + call depositForBurn)
 *   3. Build DepositData with TransferProxy as spokePool, MulticallHandler as recipient
 *   4. Compute ERC-3009 witness from DepositData
 *   5. Sign receiveWithAuthorization over (from, to=periphery, value, validAfter, validBefore, nonce=witness)
 *   6. Call depositWithAuthorization — periphery pulls USDC via ERC-3009, then calls TransferProxy which
 *      sends USDC to MulticallHandler and triggers handleV3AcrossMessage
 *
 * Usage:
 *   forge script script/DepositWithAuthorization.s.sol --rpc-url <network> --broadcast -vvvv
 *
 *   Input token must implement EIP-3009 (e.g. USDC).
 */
contract DepositWithAuthorization is Script {
    using AddressToBytes32 for address;

    // ERC-3009 typehash
    bytes32 constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        keccak256(
            "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );

    // Matches SpokePoolPeriphery.BRIDGE_WITNESS_IDENTIFIER
    bytes32 constant BRIDGE_WITNESS_IDENTIFIER = keccak256("BridgeWitness");

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        // ========================
        // === EDIT PARAMS HERE ===
        // ========================

        address spokePoolPeriphery = 0x10D8b8DaA26d307489803e10477De69C0492B610;
        address transferProxy = 0xf9EC5B0B73ed5b0C792d87e0b6FA04D4947e21d5;
        address multicallHandler = 0x0F7Ae28dE1C8532170AD4ee566B5801485c13a0E;
        address sponsoredCCTPPeriphery = 0xc9b6E5AE2e8627621F161d637c1B05f9A4b54af3;
        address burnToken = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC on Arbitrum

        uint256 amount = 1000000; // 1 USDC
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 3600;

        // ===================================
        // === 1. BUILD CCTP QUOTE & SIGN  ===
        // ===================================

        bytes memory actionDataEmpty = abi.encode(new ArbitraryEVMFlowExecutor.CompressedCall[](0));

        SponsoredCCTPInterface.SponsoredCCTPQuote memory cctpQuote = SponsoredCCTPInterface.SponsoredCCTPQuote({
            sourceDomain: 3,
            destinationDomain: 6,
            mintRecipient: address(0xd9DC78B969E9Efb1e54B625c33A21Aaf2509e6a1).toBytes32(),
            amount: amount,
            burnToken: burnToken.toBytes32(),
            destinationCaller: address(0xd9DC78B969E9Efb1e54B625c33A21Aaf2509e6a1).toBytes32(),
            maxFee: 1000,
            minFinalityThreshold: 1000,
            nonce: keccak256(abi.encodePacked(block.timestamp, deployer, vm.getNonce(deployer))),
            deadline: block.timestamp + 10800,
            maxBpsToSponsor: 400,
            maxUserSlippageBps: 400,
            finalRecipient: deployer.toBytes32(),
            finalToken: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).toBytes32(),
            destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
            accountCreationMode: uint8(AccountCreationMode.Standard),
            executionMode: uint8(SponsoredExecutionModeInterface.ExecutionMode.ArbitraryActionsToEVM),
            actionData: actionDataEmpty
        });

        bytes memory cctpSignature;
        {
            bytes32 h1 = keccak256(
                abi.encode(
                    cctpQuote.sourceDomain,
                    cctpQuote.destinationDomain,
                    cctpQuote.mintRecipient,
                    cctpQuote.amount,
                    cctpQuote.burnToken,
                    cctpQuote.destinationCaller,
                    cctpQuote.maxFee,
                    cctpQuote.minFinalityThreshold
                )
            );
            bytes32 h2 = keccak256(
                abi.encode(
                    cctpQuote.nonce,
                    cctpQuote.deadline,
                    cctpQuote.maxBpsToSponsor,
                    cctpQuote.maxUserSlippageBps,
                    cctpQuote.finalRecipient,
                    cctpQuote.finalToken,
                    cctpQuote.destinationDex,
                    cctpQuote.accountCreationMode,
                    cctpQuote.executionMode,
                    keccak256(cctpQuote.actionData)
                )
            );
            bytes32 cctpDigest = keccak256(abi.encode(h1, h2));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPrivateKey, cctpDigest);
            cctpSignature = abi.encodePacked(r, s, v);
        }

        // ============================================
        // === 2. BUILD MULTICALL HANDLER MESSAGE   ===
        // ============================================

        MulticallHandler.Call[] memory calls = new MulticallHandler.Call[](2);

        // Approve USDC to SponsoredCCTPSrcPeriphery
        calls[0] = MulticallHandler.Call({
            target: burnToken,
            callData: abi.encodeWithSelector(IERC20.approve.selector, sponsoredCCTPPeriphery, amount),
            value: 0
        });

        // Call depositForBurn
        calls[1] = MulticallHandler.Call({
            target: sponsoredCCTPPeriphery,
            callData: abi.encodeWithSelector(
                SponsoredCCTPSrcPeriphery.depositForBurn.selector,
                cctpQuote,
                cctpSignature
            ),
            value: 0
        });

        bytes memory message = abi.encode(MulticallHandler.Instructions({ calls: calls, fallbackRecipient: deployer }));

        // ============================================
        // === 3. BUILD DEPOSIT DATA                ===
        // ============================================

        // TransferProxy requires: inputToken == outputToken, inputAmount == outputAmount, destinationChainId == block.chainid
        SpokePoolPeripheryInterface.DepositData memory depositData = SpokePoolPeripheryInterface.DepositData({
            submissionFees: SpokePoolPeripheryInterface.Fees({ amount: 0, recipient: address(0) }),
            baseDepositData: SpokePoolPeripheryInterface.BaseDepositData({
                inputToken: burnToken,
                outputToken: burnToken.toBytes32(),
                outputAmount: amount,
                depositor: deployer,
                recipient: multicallHandler.toBytes32(),
                destinationChainId: block.chainid,
                exclusiveRelayer: bytes32(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 7200),
                exclusivityParameter: 0,
                message: message
            }),
            inputAmount: amount,
            spokePool: transferProxy,
            nonce: 0 // unused for authorization flow; witness becomes the nonce
        });

        // ============================================
        // === 4. SIGN ERC-3009 AUTHORIZATION       ===
        // ============================================

        // witness = keccak256(BRIDGE_WITNESS_IDENTIFIER, abi.encode(depositData))
        // This matches SpokePoolPeriphery.getERC3009DepositWitness()
        bytes32 witness = keccak256(abi.encodePacked(BRIDGE_WITNESS_IDENTIFIER, abi.encode(depositData)));

        bytes32 tokenDomainSeparator = _getTokenDomainSeparator(burnToken);

        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                deployer, // from
                spokePoolPeriphery, // to
                amount, // value (no submission fees)
                validAfter,
                validBefore,
                witness // nonce
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tokenDomainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPrivateKey, digest);
        bytes memory receiveWithAuthSignature = abi.encodePacked(r, s, v);

        // ============================================
        // === 5. EXECUTE                           ===
        // ============================================

        console.log("=== depositWithAuthorization -> TransferProxy -> MulticallHandler -> depositForBurn ===");
        console.log("Signer:", deployer);
        console.log("SpokePoolPeriphery:", spokePoolPeriphery);
        console.log("TransferProxy (spokePool):", transferProxy);
        console.log("MulticallHandler (recipient):", multicallHandler);
        console.log("SponsoredCCTPSrcPeriphery:", sponsoredCCTPPeriphery);
        console.log("Burn Token:", burnToken);
        console.log("Amount:", amount);
        console.log("Witness (ERC-3009 nonce):");
        console.logBytes32(witness);

        vm.broadcast(deployerPrivateKey);
        SpokePoolPeripheryInterface(spokePoolPeriphery).depositWithAuthorization(
            deployer,
            depositData,
            validAfter,
            validBefore,
            receiveWithAuthSignature
        );

        console.log("Transaction submitted successfully");
    }

    /// @dev Reads DOMAIN_SEPARATOR() from the token contract.
    function _getTokenDomainSeparator(address token) internal view returns (bytes32) {
        (bool success, bytes memory result) = token.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(success && result.length == 32, "Token does not expose DOMAIN_SEPARATOR()");
        return abi.decode(result, (bytes32));
    }
}
