// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";
import { SponsoredCCTPSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";
import { SponsoredCCTPInterface } from "../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { AccountCreationMode } from "../../../contracts/periphery/mintburn/Structs.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";
import { HyperCoreLib } from "../../../contracts/libraries/HyperCoreLib.sol";

// Usage (pick the entry point matching your use case):
//
// 1) DirectToCore (most common):
//    forge script script/mintburn/cctp/createSponsoredDeposit.sol:CreateSponsoredDeposit \
//      --sig "runDirectToCore(uint256,uint32,address,address,address,uint256)" \
//      1000000 19 0xMINT_RECIPIENT 0xFINAL_RECIPIENT 0xFINAL_TOKEN 100 \
//      --rpc-url <network> -vvvv
//    Args: amount, destinationDomain, mintRecipient, finalRecipient, finalToken, maxFeeBps
//
// 2) DirectToCore with custom slippage/sponsor bps:
//    forge script script/mintburn/cctp/createSponsoredDeposit.sol:CreateSponsoredDeposit \
//      --sig "runDirectToCoreWithFees(uint256,uint32,address,address,address,uint256,uint256,uint256)" \
//      1000000 19 0xMINT_RECIPIENT 0xFINAL_RECIPIENT 0xFINAL_TOKEN 100 400 400 \
//      --rpc-url <network> -vvvv
//    Args: amount, destinationDomain, mintRecipient, finalRecipient, finalToken, maxFeeBps, maxBpsToSponsor, maxUserSlippageBps
//
// 3) Arbitrary execution mode (with action data):
//    forge script script/mintburn/cctp/createSponsoredDeposit.sol:CreateSponsoredDeposit \
//      --sig "runArbitrary(uint256,uint32,address,address,address,uint256,uint8,bytes)" \
//      1000000 19 0xMINT_RECIPIENT 0xFINAL_RECIPIENT 0xFINAL_TOKEN 100 1 0xACTION_DATA \
//      --rpc-url <network> -vvvv
//    Args: amount, destinationDomain, mintRecipient, finalRecipient, finalToken, maxFeeBps, executionMode, actionData
//
// 4) Full control over all parameters:
//    forge script script/mintburn/cctp/createSponsoredDeposit.sol:CreateSponsoredDeposit \
//      --sig "runFull(uint256,uint32,address,address,address,address,uint256,uint32,uint256,uint256,uint256,uint32,uint8,uint8,bytes)" \
//      ...args --rpc-url <network> -vvvv
//    Args: amount, destinationDomain, mintRecipient, finalRecipient, finalToken, destinationCaller,
//          maxFeeBps, minFinalityThreshold, maxBpsToSponsor, maxUserSlippageBps, deadlineOffset,
//          destinationDex, accountCreationMode, executionMode, actionData
//
// Note: maxFeeBps is used to compute maxFee = amount * maxFeeBps / 10000
//
// Optional env vars:
//   APPROVE_AMOUNT - If set, approve USDC to the periphery before deposit
//   GAS_LIMIT      - Gas limit for depositForBurn (default: 1000000)
contract CreateSponsoredDeposit is DeploymentUtils {
    using AddressToBytes32 for address;

    // DirectToCore with default slippage/sponsor bps (400 each).
    function runDirectToCore(
        uint256 amount,
        uint32 destinationDomain,
        address mintRecipient,
        address finalRecipient,
        address finalToken,
        uint256 maxFeeBps
    ) external {
        _execute(
            amount,
            destinationDomain,
            mintRecipient,
            mintRecipient, // destinationCaller = mintRecipient
            finalRecipient,
            finalToken,
            (amount * maxFeeBps) / 10000,
            1000, // minFinalityThreshold
            400, // maxBpsToSponsor
            400, // maxUserSlippageBps
            HyperCoreLib.CORE_SPOT_DEX_ID,
            uint8(AccountCreationMode.Standard),
            uint8(SponsoredCCTPInterface.ExecutionMode.DirectToCore),
            "" // empty actionData
        );
    }

    // DirectToCore with custom slippage/sponsor bps.
    function runDirectToCoreWithFees(
        uint256 amount,
        uint32 destinationDomain,
        address mintRecipient,
        address finalRecipient,
        address finalToken,
        uint256 maxFeeBps,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps
    ) external {
        _execute(
            amount,
            destinationDomain,
            mintRecipient,
            mintRecipient,
            finalRecipient,
            finalToken,
            (amount * maxFeeBps) / 10000,
            1000,
            maxBpsToSponsor,
            maxUserSlippageBps,
            HyperCoreLib.CORE_SPOT_DEX_ID,
            uint8(AccountCreationMode.Standard),
            uint8(SponsoredCCTPInterface.ExecutionMode.DirectToCore),
            ""
        );
    }

    // Arbitrary execution mode (ArbitraryActionsToCore=1 or ArbitraryActionsToEVM=2) with action data.
    function runArbitrary(
        uint256 amount,
        uint32 destinationDomain,
        address mintRecipient,
        address finalRecipient,
        address finalToken,
        uint256 maxFeeBps,
        uint8 executionMode,
        bytes calldata actionData
    ) external {
        require(executionMode == 1 || executionMode == 2, "Use runDirectToCore for mode 0");
        require(actionData.length > 0, "actionData required for arbitrary execution modes");

        _execute(
            amount,
            destinationDomain,
            mintRecipient,
            mintRecipient,
            finalRecipient,
            finalToken,
            (amount * maxFeeBps) / 10000,
            1000,
            400,
            400,
            HyperCoreLib.CORE_SPOT_DEX_ID,
            uint8(AccountCreationMode.Standard),
            executionMode,
            actionData
        );
    }

    // Full control over every parameter.
    function runFull(
        uint256 amount,
        uint32 destinationDomain,
        address mintRecipient,
        address finalRecipient,
        address finalToken,
        address destinationCaller,
        uint256 maxFeeBps,
        uint32 minFinalityThreshold,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        uint256 deadlineOffset,
        uint32 destinationDex,
        uint8 accountCreationMode,
        uint8 executionMode,
        bytes calldata actionData
    ) external {
        require(executionMode <= 2, "Invalid executionMode");
        require(accountCreationMode <= 1, "Invalid accountCreationMode");

        _execute(
            amount,
            destinationDomain,
            mintRecipient,
            destinationCaller,
            finalRecipient,
            finalToken,
            (amount * maxFeeBps) / 10000,
            minFinalityThreshold,
            maxBpsToSponsor,
            maxUserSlippageBps,
            destinationDex,
            accountCreationMode,
            executionMode,
            actionData
        );
    }

    function _execute(
        uint256 amount,
        uint32 destinationDomain,
        address mintRecipient,
        address destinationCaller,
        address finalRecipient,
        address finalToken,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        uint32 destinationDex,
        uint8 accountCreationMode,
        uint8 executionMode,
        bytes memory actionData
    ) internal {
        console.log("Creating sponsored deposit...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        _loadConfig("./script/mintburn/cctp/config.toml", true);

        address contractAddress = config.get("sponsoredCCTPSrcPeriphery").toAddress();
        SponsoredCCTPSrcPeriphery sponsoredCCTPSrcPeriphery = SponsoredCCTPSrcPeriphery(contractAddress);

        require(sponsoredCCTPSrcPeriphery.signer() == deployer, "quote signer mismatch");

        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = SponsoredCCTPInterface.SponsoredCCTPQuote({
            sourceDomain: config.get("cctpDomainId").toUint32(),
            destinationDomain: destinationDomain,
            mintRecipient: mintRecipient.toBytes32(),
            amount: amount,
            burnToken: config.get("usdc").toAddress().toBytes32(),
            destinationCaller: destinationCaller.toBytes32(),
            maxFee: maxFee,
            minFinalityThreshold: minFinalityThreshold,
            nonce: keccak256(abi.encodePacked(block.timestamp, deployer, vm.getNonce(deployer))),
            deadline: block.timestamp + 10800,
            maxBpsToSponsor: maxBpsToSponsor,
            maxUserSlippageBps: maxUserSlippageBps,
            finalRecipient: finalRecipient.toBytes32(),
            finalToken: finalToken.toBytes32(),
            destinationDex: destinationDex,
            accountCreationMode: accountCreationMode,
            executionMode: executionMode,
            actionData: actionData
        });

        console.log("SponsoredCCTPQuote:");
        console.log("  sourceDomain:", quote.sourceDomain);
        console.log("  destinationDomain:", quote.destinationDomain);
        console.log("  amount:", quote.amount);
        console.log("  maxFee:", quote.maxFee);
        console.log("  maxBpsToSponsor:", quote.maxBpsToSponsor);
        console.log("  maxUserSlippageBps:", quote.maxUserSlippageBps);
        console.log("  executionMode:", quote.executionMode);
        console.log("  nonce:");
        console.logBytes32(quote.nonce);
        console.log("  deadline:", quote.deadline);

        // Create signature hash
        bytes32 hash1 = keccak256(
            abi.encode(
                quote.sourceDomain,
                quote.destinationDomain,
                quote.mintRecipient,
                quote.amount,
                quote.burnToken,
                quote.destinationCaller,
                quote.maxFee,
                quote.minFinalityThreshold
            )
        );

        bytes32 hash2 = keccak256(
            abi.encode(
                quote.nonce,
                quote.deadline,
                quote.maxBpsToSponsor,
                quote.maxUserSlippageBps,
                quote.finalRecipient,
                quote.finalToken,
                quote.destinationDex,
                quote.accountCreationMode,
                quote.executionMode,
                keccak256(quote.actionData)
            )
        );

        bytes32 typedDataHash = keccak256(abi.encode(hash1, hash2));
        console.log("Signature Hash:");
        console.logBytes32(typedDataHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPrivateKey, typedDataHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("Signature created, signer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        uint256 approveAmount = IERC20(config.get("usdc").toAddress()).balanceOf(deployer);
        if (approveAmount > 0) {
            IERC20(config.get("usdc").toAddress()).approve(address(sponsoredCCTPSrcPeriphery), approveAmount);
            console.log("Approved USDC:", approveAmount);
        }

        uint256 gasLimit = vm.envOr("GAS_LIMIT", uint256(1000000));
        console.log("Calling depositForBurn...");
        sponsoredCCTPSrcPeriphery.depositForBurn{ gas: gasLimit }(quote, signature);

        console.log("Transaction completed successfully!");

        vm.stopBroadcast();
    }
}
