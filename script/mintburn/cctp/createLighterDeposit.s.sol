// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SponsoredCCTPSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";
import { SponsoredCCTPDstPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPDstPeriphery.sol";
import { ArbitraryEVMFlowExecutor } from "../../../contracts/periphery/mintburn/ArbitraryEVMFlowExecutor.sol";
import { SponsoredCCTPInterface } from "../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";
import { MulticallHandler } from "../../../contracts/handlers/MulticallHandler.sol";

interface IAdditionalZkLighter {
    // _routeType is an enum in the original contract, mapped to uint8 here
    function deposit(address _to, uint16 _assetIndex, uint8 _routeType, uint256 _amount) external payable;
}

// Run: forge script script/mintburn/cctp/createLighterDeposit.s.sol:CreateLighterDeposit --rpc-url arbitrum -vvvv
contract CreateLighterDeposit is Script, Config {
    using AddressToBytes32 for address;

    struct DepositEnv {
        address srcPeriphery;
        address srcUsdc;
        uint32 srcDomain;
        address dstPeriphery;
        address dstUsdc;
        address multicallHandler;
        address zkLighter;
    }

    function run() external {
        console.log("Creating Lighter sponsored deposit...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Load config and create forks for all chains
        _loadConfigAndForks("./script/mintburn/cctp/configLighter.toml", false);

        // Resolve environment from source and destination chains
        DepositEnv memory env = _resolveEnv();

        // Verify that the signer matches the contract's signer
        SponsoredCCTPSrcPeriphery sponsoredCCTPSrcPeriphery = SponsoredCCTPSrcPeriphery(env.srcPeriphery);
        require(sponsoredCCTPSrcPeriphery.signer() == deployer, "quote signer mismatch");

        // Build and execute the deposit
        _execute(env, deployerPrivateKey, deployer);
    }

    function _resolveEnv() internal returns (DepositEnv memory env) {
        // Source chain (current chain from --rpc-url)
        uint256 srcChainId = block.chainid;
        uint256 srcForkId = forkOf[srcChainId];
        require(srcForkId != 0, "src chain not in config");
        vm.selectFork(srcForkId);

        env.srcPeriphery = config.get("sponsoredCCTPSrcPeriphery").toAddress();
        env.srcUsdc = config.get("usdc").toAddress();
        env.srcDomain = config.get("cctpDomainId").toUint32();
        require(env.srcPeriphery != address(0) && env.srcUsdc != address(0), "missing src config");

        // Destination chain (Ethereum Mainnet, chain ID 1)
        uint256 dstChainId = 1;
        uint256 dstForkId = forkOf[dstChainId];
        require(dstForkId != 0, "dst chain (mainnet) not in config");
        vm.selectFork(dstForkId);

        env.dstPeriphery = config.get("sponsoredCCTPDstPeriphery").toAddress();
        env.dstUsdc = config.get("usdc").toAddress();
        env.zkLighter = config.get("zkLighter").toAddress();
        require(env.dstPeriphery != address(0) && env.dstUsdc != address(0), "missing dst config");
        require(env.zkLighter != address(0), "zkLighter not in config");
        require(env.dstPeriphery.code.length > 0, "dst periphery not a contract");
        env.multicallHandler = SponsoredCCTPDstPeriphery(payable(env.dstPeriphery)).multicallHandler();
        require(env.multicallHandler != address(0), "multicallhandler not set on destination");

        // Switch back to source fork for execution
        vm.selectFork(srcForkId);
    }

    function _execute(DepositEnv memory env, uint256 deployerPrivateKey, address deployer) internal {
        // Parameters for Lighter Deposit
        address lighterRecipient = deployer;
        uint16 assetIndex = 3; // USDC Asset Index
        uint8 routeType = 0; // RouteType
        uint256 amount = 5000000; // 5 USDC (6 decimals)

        // Build actionData for arbitrary EVM flow
        bytes memory actionData = _buildActionData(env, lighterRecipient, assetIndex, routeType);

        // Create the SponsoredCCTPQuote
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = SponsoredCCTPInterface.SponsoredCCTPQuote({
            sourceDomain: env.srcDomain,
            destinationDomain: 0, // Ethereum CCTP domain
            mintRecipient: env.dstPeriphery.toBytes32(),
            amount: amount,
            burnToken: env.srcUsdc.toBytes32(),
            destinationCaller: env.dstPeriphery.toBytes32(),
            maxFee: 100,
            minFinalityThreshold: 1000,
            nonce: keccak256(abi.encodePacked(block.timestamp, deployer, vm.getNonce(deployer))),
            deadline: block.timestamp + 10800, // 3 hours
            maxBpsToSponsor: 0, // Non-sponsored flow
            maxUserSlippageBps: 0,
            finalRecipient: lighterRecipient.toBytes32(),
            finalToken: env.dstUsdc.toBytes32(),
            executionMode: uint8(SponsoredCCTPInterface.ExecutionMode.ArbitraryActionsToEVM),
            actionData: actionData
        });

        _logQuote(quote);

        // Sign the quote
        bytes memory signature = _signQuote(quote, deployerPrivateKey);

        console.log("Signature created");
        console.log("Signer:", deployer);

        // Execute deposit
        vm.startBroadcast(deployerPrivateKey);

        // Approve USDC if needed
        // IERC20(env.srcUsdc).approve(env.srcPeriphery, amount);

        console.log("Calling depositForBurn...");
        SponsoredCCTPSrcPeriphery sponsoredCCTPSrcPeriphery = SponsoredCCTPSrcPeriphery(env.srcPeriphery);
        try sponsoredCCTPSrcPeriphery.depositForBurn{ gas: 1000000 }(quote, signature) {
            console.log("Transaction completed successfully!");
        } catch Error(string memory reason) {
            console.log("Transaction failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Transaction failed with low level data");
            console.logBytes(lowLevelData);
        }
        vm.stopBroadcast();
    }

    function _buildActionData(
        DepositEnv memory env,
        address lighterRecipient,
        uint16 assetIndex,
        uint8 routeType
    ) internal pure returns (bytes memory) {
        // Construct the inner call to Lighter.deposit with placeholder amount (0)
        bytes memory depositCallData = abi.encodeWithSelector(
            IAdditionalZkLighter.deposit.selector,
            lighterRecipient,
            assetIndex,
            routeType,
            0 // Placeholder amount - MulticallHandler will fill this in
        );

        // Replacement: inject USDC balance at offset 100
        // Offset calculation: Selector (4) + Arg1 (32) + Arg2 (32) + Arg3 (32) = 100
        MulticallHandler.Replacement[] memory replacements = new MulticallHandler.Replacement[](1);
        replacements[0] = MulticallHandler.Replacement({ token: env.dstUsdc, offset: 100 });

        // Construct makeCallWithBalance call
        bytes memory makeCallWithBalanceCallData = abi.encodeWithSelector(
            MulticallHandler.makeCallWithBalance.selector,
            env.zkLighter,
            depositCallData,
            0, // value (unused for token balance replacement)
            replacements
        );

        // Wrap into CompressedCall for ArbitraryEVMFlowExecutor
        ArbitraryEVMFlowExecutor.CompressedCall[]
            memory compressedCalls = new ArbitraryEVMFlowExecutor.CompressedCall[](1);
        compressedCalls[0] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: env.multicallHandler,
            callData: makeCallWithBalanceCallData
        });

        return abi.encode(compressedCalls);
    }

    function _signQuote(
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        uint256 privateKey
    ) internal pure returns (bytes memory) {
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, typedDataHash);
        return abi.encodePacked(r, s, v);
    }

    function _logQuote(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote) internal pure {
        console.log("SponsoredCCTPQuote created:");
        console.log("  sourceDomain:", quote.sourceDomain);
        console.log("  destinationDomain:", quote.destinationDomain);
        console.log("  amount:", quote.amount);
        console.log("  nonce:");
        console.logBytes32(quote.nonce);
        console.log("  deadline:", quote.deadline);
        console.log("  actionData length:", quote.actionData.length);
    }
}
