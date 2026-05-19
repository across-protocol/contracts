// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";
import { SponsoredCCTPSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";
import { SponsoredCCTPInterface } from "../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { SponsoredExecutionModeInterface } from "../../../contracts/interfaces/SponsoredExecutionModeInterface.sol";
import { AccountCreationMode } from "../../../contracts/periphery/mintburn/Structs.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";
import { HyperCoreLib } from "../../../contracts/libraries/HyperCoreLib.sol";
import { ArbitraryEVMFlowExecutor } from "../../../contracts/periphery/mintburn/ArbitraryEVMFlowExecutor.sol";

// Usage (pick the entry point matching your use case):
//
// 1) DirectToCore (most common):
//    forge script script/mintburn/cctp/createSponsoredDeposit.sol:CreateSponsoredDeposit \
//      --sig "runDirectToCore(address,uint256,uint32,address,address,address,uint256,bool)" \
//      0xTOKEN 1000000 19 0xMINT_RECIPIENT 0xFINAL_RECIPIENT 0xFINAL_TOKEN 100 false \
//      --rpc-url <network> -vvvv
//    Args: token, amount, destinationDomain, mintRecipient, finalRecipient, finalToken, maxFeeBps, showCast
//
// 2) DirectToCore with custom slippage/sponsor bps:
//    forge script script/mintburn/cctp/createSponsoredDeposit.sol:CreateSponsoredDeposit \
//      --sig "runDirectToCoreWithFees(address,uint256,uint32,address,address,address,uint256,uint256,uint256,bool)" \
//      0xTOKEN 1000000 19 0xMINT_RECIPIENT 0xFINAL_RECIPIENT 0xFINAL_TOKEN 100 400 400 false \
//      --rpc-url <network> -vvvv
//    Args: token, amount, destinationDomain, mintRecipient, finalRecipient, finalToken, maxFeeBps, maxBpsToSponsor, maxUserSlippageBps, showCast
//
// 3) Arbitrary execution mode (with action data):
//    forge script script/mintburn/cctp/createSponsoredDeposit.sol:CreateSponsoredDeposit \
//      --sig "runArbitrary(address,uint256,uint32,address,address,address,uint256,uint8,bytes,bool)" \
//      0xTOKEN 1000000 19 0xMINT_RECIPIENT 0xFINAL_RECIPIENT 0xFINAL_TOKEN 100 1 0xACTION_DATA false \
//      --rpc-url <network> -vvvv
//    Args: token, amount, destinationDomain, mintRecipient, finalRecipient, finalToken, maxFeeBps, executionMode, actionData, showCast
//
// 4) Full control over all parameters:
//    forge script script/mintburn/cctp/createSponsoredDeposit.sol:CreateSponsoredDeposit \
//      --sig "runFull(address,uint256,uint32,address,address,address,address,uint256,uint32,uint256,uint256,uint256,uint32,uint8,uint8,bytes,bool)" \
//      ...args --rpc-url <network> -vvvv
//    Args: token, amount, destinationDomain, mintRecipient, finalRecipient, finalToken, destinationCaller,
//          maxFeeBps, minFinalityThreshold, maxBpsToSponsor, maxUserSlippageBps, deadlineOffset,
//          destinationDex, accountCreationMode, executionMode, actionData, showCast
//
// Note: maxFeeBps is used to compute maxFee = amount * maxFeeBps / 10000
//       `token` is the burn token (e.g. the chain's USDC for canonical CCTP, or another supported token).
//       `showCast=true` prints a copy-paste cast invocation and skips the broadcast.
//
// Optional env vars:
//   APPROVE_AMOUNT - If set, approve `token` to the periphery before deposit
//   GAS_LIMIT      - Gas limit for depositForBurn (default: 1000000)
contract CreateSponsoredDeposit is DeploymentUtils {
    using AddressToBytes32 for address;

    struct ExecuteParams {
        address token;
        uint256 amount;
        uint32 destinationDomain;
        address mintRecipient;
        address destinationCaller;
        address finalRecipient;
        address finalToken;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        uint256 maxBpsToSponsor;
        uint256 maxUserSlippageBps;
        uint32 destinationDex;
        uint8 accountCreationMode;
        uint8 executionMode;
        bytes actionData;
    }

    // DirectToCore with default slippage/sponsor bps (400 each).
    // Set showCast=true to print a cast invocation instead of broadcasting.
    function runDirectToCore(
        address token,
        uint256 amount,
        uint32 destinationDomain,
        address mintRecipient,
        address finalRecipient,
        address finalToken,
        uint256 maxFeeBps,
        bool showCast
    ) external {
        _execute(
            ExecuteParams({
                token: token,
                amount: amount,
                destinationDomain: destinationDomain,
                mintRecipient: mintRecipient,
                destinationCaller: mintRecipient, // destinationCaller = mintRecipient
                finalRecipient: finalRecipient,
                finalToken: finalToken,
                maxFee: (amount * maxFeeBps) / 10000,
                minFinalityThreshold: 1000,
                maxBpsToSponsor: 400,
                maxUserSlippageBps: 400,
                destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
                accountCreationMode: uint8(AccountCreationMode.Standard),
                executionMode: uint8(SponsoredExecutionModeInterface.ExecutionMode.DirectToCore),
                actionData: ""
            }),
            showCast
        );
    }

    // DirectToCore with custom slippage/sponsor bps.
    function runDirectToCoreWithFees(
        address token,
        uint256 amount,
        uint32 destinationDomain,
        address mintRecipient,
        address finalRecipient,
        address finalToken,
        uint256 maxFeeBps,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        bool showCast
    ) external {
        _execute(
            ExecuteParams({
                token: token,
                amount: amount,
                destinationDomain: destinationDomain,
                mintRecipient: mintRecipient,
                destinationCaller: mintRecipient,
                finalRecipient: finalRecipient,
                finalToken: finalToken,
                maxFee: (amount * maxFeeBps) / 10000,
                minFinalityThreshold: 1000,
                maxBpsToSponsor: maxBpsToSponsor,
                maxUserSlippageBps: maxUserSlippageBps,
                destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
                accountCreationMode: uint8(AccountCreationMode.Standard),
                executionMode: uint8(SponsoredExecutionModeInterface.ExecutionMode.DirectToCore),
                actionData: ""
            }),
            showCast
        );
    }

    // Arbitrary execution mode (ArbitraryActionsToCore=1 or ArbitraryActionsToEVM=2) with action data.
    function runArbitrary(
        address token,
        uint256 amount,
        uint32 destinationDomain,
        address mintRecipient,
        address finalRecipient,
        address finalToken,
        uint256 maxFeeBps,
        uint8 executionMode,
        bytes memory actionData,
        bool showCast
    ) external {
        require(executionMode == 1 || executionMode == 2, "Use runDirectToCore for mode 0");
        if (actionData.length == 0) {
            ArbitraryEVMFlowExecutor.CompressedCall[]
                memory actionDataBytes = new ArbitraryEVMFlowExecutor.CompressedCall[](0);
            actionData = abi.encode(actionDataBytes);
        }

        _execute(
            ExecuteParams({
                token: token,
                amount: amount,
                destinationDomain: destinationDomain,
                mintRecipient: mintRecipient,
                destinationCaller: mintRecipient,
                finalRecipient: finalRecipient,
                finalToken: finalToken,
                maxFee: (amount * maxFeeBps) / 100000,
                minFinalityThreshold: 1000,
                maxBpsToSponsor: 400,
                maxUserSlippageBps: 400,
                destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
                accountCreationMode: uint8(AccountCreationMode.Standard),
                executionMode: executionMode,
                actionData: actionData
            }),
            showCast
        );
    }

    // Full control over every parameter.
    function runFull(
        address token,
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
        bytes calldata actionData,
        bool showCast
    ) external {
        require(executionMode <= 2, "Invalid executionMode");
        require(accountCreationMode <= 1, "Invalid accountCreationMode");

        _execute(
            ExecuteParams({
                token: token,
                amount: amount,
                destinationDomain: destinationDomain,
                mintRecipient: mintRecipient,
                destinationCaller: destinationCaller,
                finalRecipient: finalRecipient,
                finalToken: finalToken,
                maxFee: (amount * maxFeeBps) / 10000,
                minFinalityThreshold: minFinalityThreshold,
                maxBpsToSponsor: maxBpsToSponsor,
                maxUserSlippageBps: maxUserSlippageBps,
                destinationDex: destinationDex,
                accountCreationMode: accountCreationMode,
                executionMode: executionMode,
                actionData: actionData
            }),
            showCast
        );
    }

    function _execute(ExecuteParams memory p, bool showCast) internal {
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
            destinationDomain: p.destinationDomain,
            mintRecipient: p.mintRecipient.toBytes32(),
            amount: p.amount,
            burnToken: p.token.toBytes32(),
            destinationCaller: p.destinationCaller.toBytes32(),
            maxFee: p.maxFee,
            minFinalityThreshold: p.minFinalityThreshold,
            nonce: keccak256(abi.encodePacked(block.timestamp, deployer, vm.getNonce(deployer))),
            deadline: block.timestamp + 10800,
            maxBpsToSponsor: p.maxBpsToSponsor,
            maxUserSlippageBps: p.maxUserSlippageBps,
            finalRecipient: p.finalRecipient.toBytes32(),
            finalToken: p.finalToken.toBytes32(),
            destinationDex: p.destinationDex,
            accountCreationMode: p.accountCreationMode,
            executionMode: p.executionMode,
            actionData: p.actionData
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

        if (showCast) {
            _logCastCommand(address(sponsoredCCTPSrcPeriphery), quote, signature);
            return;
        }

        vm.startBroadcast(deployerPrivateKey);

        uint256 approveAmount = IERC20(p.token).balanceOf(deployer);
        if (approveAmount > 0) {
            IERC20(p.token).approve(address(sponsoredCCTPSrcPeriphery), approveAmount);
            console.log("Approved token:", approveAmount);
        }

        uint256 gasLimit = vm.envOr("GAS_LIMIT", uint256(1000000));
        console.log("Calling depositForBurn...");
        sponsoredCCTPSrcPeriphery.depositForBurn{ gas: gasLimit }(quote, signature);

        console.log("Transaction completed successfully!");

        vm.stopBroadcast();
    }

    function _logCastCommand(
        address target,
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        bytes memory signature
    ) internal view {
        string memory tuple = string.concat(
            "(",
            vm.toString(uint256(quote.sourceDomain)),
            ",",
            vm.toString(uint256(quote.destinationDomain)),
            ",",
            vm.toString(quote.mintRecipient),
            ",",
            vm.toString(quote.amount),
            ",",
            vm.toString(quote.burnToken),
            ",",
            vm.toString(quote.destinationCaller),
            ","
        );
        tuple = string.concat(
            tuple,
            vm.toString(quote.maxFee),
            ",",
            vm.toString(uint256(quote.minFinalityThreshold)),
            ",",
            vm.toString(quote.nonce),
            ",",
            vm.toString(quote.deadline),
            ",",
            vm.toString(quote.maxBpsToSponsor),
            ",",
            vm.toString(quote.maxUserSlippageBps),
            ","
        );
        tuple = string.concat(
            tuple,
            vm.toString(quote.finalRecipient),
            ",",
            vm.toString(quote.finalToken),
            ",",
            vm.toString(uint256(quote.destinationDex)),
            ",",
            vm.toString(uint256(quote.accountCreationMode)),
            ",",
            vm.toString(uint256(quote.executionMode)),
            ",",
            vm.toString(quote.actionData),
            ")"
        );

        string
            memory funcSig = "depositForBurn((uint32,uint32,bytes32,uint256,bytes32,bytes32,uint256,uint32,bytes32,uint256,uint256,uint256,bytes32,bytes32,uint32,uint8,uint8,bytes),bytes)";

        string memory cmd = string.concat(
            "cast send ",
            vm.toString(target),
            ' \\\n  "',
            funcSig,
            '" \\\n  "',
            tuple,
            '" \\\n  ',
            vm.toString(signature),
            " \\\n  --rpc-url <network> --account dev"
        );

        console.log("=== cast command (copy/paste; swap `cast send` for `cast call` to dry-run) ===");
        console.log(cmd);
        console.log("=============================================================================");
    }
}
