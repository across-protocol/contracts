// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";
import { SponsoredCCTPSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";
import { ArbitraryEVMFlowExecutor } from "../../../contracts/periphery/mintburn/ArbitraryEVMFlowExecutor.sol";
import { SponsoredCCTPInterface } from "../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";

interface IHyperSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    function multicall(uint256 deadline, bytes[] calldata data) external payable returns (bytes[] memory results);
}

// Run: forge script script/mintburn/cctp/createSponsoredDeposit.sol:CreateSponsoredDeposit --rpc-url <network> -vvvv
contract CreateSponsoredDeposit is DeploymentUtils {
    using AddressToBytes32 for address;

    function run() external {
        console.log("Creating sponsored deposit...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        _loadConfig("./script/mintburn/cctp/config.toml", true);

        address contractAddress = config.get("sponsoredCCTPSrcPeriphery").toAddress();
        SponsoredCCTPSrcPeriphery sponsoredCCTPSrcPeriphery = SponsoredCCTPSrcPeriphery(contractAddress);

        // Verify that the signer matches the contract's signer
        require(sponsoredCCTPSrcPeriphery.signer() == deployer, "quote signer mismatch");

        ArbitraryEVMFlowExecutor.CompressedCall[]
            memory compressedCalls = new ArbitraryEVMFlowExecutor.CompressedCall[](2);
        compressedCalls[0] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: address(0xb88339CB7199b77E23DB6E890353E22632Ba630f),
            callData: abi.encodeWithSelector(
                IERC20.approve.selector,
                // HyperSwap Router
                address(0x6D99e7f6747AF2cDbB5164b6DD50e40D4fDe1e77),
                99990
            )
        });
        bytes[] memory hyperSwapRouterCalls = new bytes[](1);
        hyperSwapRouterCalls[0] = abi.encodeWithSelector(
            IHyperSwapRouter.exactInputSingle.selector,
            IHyperSwapRouter.ExactInputSingleParams({
                tokenIn: address(0xb88339CB7199b77E23DB6E890353E22632Ba630f),
                tokenOut: address(0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb),
                fee: 100,
                recipient: address(0x369232198fBBe6b42921A79B2D3ea4430d378c00),
                amountIn: 99990,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        compressedCalls[1] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: address(0x6D99e7f6747AF2cDbB5164b6DD50e40D4fDe1e77),
            callData: abi.encodeWithSelector(
                IHyperSwapRouter.multicall.selector,
                block.timestamp + 60 * 20,
                hyperSwapRouterCalls
            )
        });
        bytes memory actionData = abi.encode(compressedCalls);
        bytes memory actionDataEmpty = abi.encode(new ArbitraryEVMFlowExecutor.CompressedCall[](0));
        bytes memory emptyActionData = "";

        // Create the SponsoredCCTPQuote
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = SponsoredCCTPInterface.SponsoredCCTPQuote({
            sourceDomain: config.get("cctpDomainId").toUint32(), // Arbitrum CCTP domain
            destinationDomain: 19, // HyperEVM CCTP domain
            mintRecipient: address(0xb63c02e60C05F05975653edC83F876C334E07C6d).toBytes32(), // Destination handler contract
            amount: 10000, // 100 USDC (6 decimals)
            burnToken: config.get("usdc").toAddress().toBytes32(), // USDC on Arbitrum
            destinationCaller: address(0xb63c02e60C05F05975653edC83F876C334E07C6d).toBytes32(), // Destination handler contract
            maxFee: 1, // 0 max fee
            minFinalityThreshold: 1000, // Minimum finality threshold
            nonce: keccak256(abi.encodePacked(block.timestamp, deployer, vm.getNonce(deployer))), // Generate nonce
            deadline: block.timestamp + 10800, // 3 hours from now
            maxBpsToSponsor: 400, // 4% max sponsorship (400 basis points)
            maxUserSlippageBps: 0, // 4% max user slippage (400 basis points)
            finalRecipient: address(0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D).toBytes32(), // Final recipient
            finalToken: address(0xb88339CB7199b77E23DB6E890353E22632Ba630f).toBytes32(), // USDC on HyperEVM
            executionMode: uint8(SponsoredCCTPInterface.ExecutionMode.DirectToCore), // DirectToCore mode
            actionData: emptyActionData // Empty for DirectToCore mode
        });

        console.log("SponsoredCCTPQuote created:");
        console.log("  sourceDomain:", quote.sourceDomain);
        console.log("  destinationDomain:", quote.destinationDomain);
        console.log("  amount:", quote.amount);
        console.log("  nonce:");
        console.logBytes32(quote.nonce);
        console.log("  deadline:", quote.deadline);
        console.logBytes(quote.actionData);

        // Create signature hash (same logic as TypeScript)
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
                quote.executionMode,
                keccak256(quote.actionData)
            )
        );

        bytes32 typedDataHash = keccak256(abi.encode(hash1, hash2));
        console.log("Signature Hash:");
        console.logBytes32(typedDataHash);

        // Sign the hash using the deployer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPrivateKey, typedDataHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("Signature created");
        console.log("Signer:", deployer);

        // Call depositForBurn
        vm.startBroadcast(deployerPrivateKey);

        console.log("Calling depositForBurn...");
        sponsoredCCTPSrcPeriphery.depositForBurn(quote, signature);

        console.log("Transaction completed successfully!");

        vm.stopBroadcast();
    }
}
