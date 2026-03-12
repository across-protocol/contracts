// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { SponsoredOFTSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";
import { SponsoredOFTInterface } from "../../../contracts/interfaces/SponsoredOFTInterface.sol";
import { SponsoredCCTPInterface } from "../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { SponsoredExecutionModeInterface } from "../../../contracts/interfaces/SponsoredExecutionModeInterface.sol";
import { DstOFTHandler } from "../../../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";
import { SponsoredCCTPSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";
import { ArbitraryEVMFlowExecutor } from "../../../contracts/periphery/mintburn/ArbitraryEVMFlowExecutor.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";
import { HyperCoreLib } from "../../../contracts/libraries/HyperCoreLib.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { MulticallHandler } from "../../../contracts/handlers/MulticallHandler.sol";
import { DonationBox } from "../../../contracts/chain-adapters/DonationBox.sol";

interface IUniswapV3RouterLike {
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
}

library DebugDirectQuoteSignLib {
    function hashMemory(SponsoredOFTInterface.SignedQuoteParams memory p) internal pure returns (bytes32) {
        bytes32 hash1 = keccak256(
            abi.encode(
                p.srcEid,
                p.dstEid,
                p.destinationHandler,
                p.amountLD,
                p.nonce,
                p.deadline,
                p.maxBpsToSponsor,
                p.maxUserSlippageBps,
                p.finalRecipient
            )
        );

        bytes32 hash2 = keccak256(
            abi.encode(
                p.finalToken,
                p.destinationDex,
                p.lzReceiveGasLimit,
                p.lzComposeGasLimit,
                p.maxOftFeeBps,
                p.accountCreationMode,
                p.executionMode,
                keccak256(p.actionData)
            )
        );

        return keccak256(abi.encode(hash1, hash2));
    }

    function signMemory(
        Vm vm,
        uint256 pk,
        SponsoredOFTInterface.SignedQuoteParams memory p
    ) internal pure returns (bytes memory) {
        bytes32 digest = hashMemory(p);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}

library DebugCCTPQuoteSignLib {
    function hashMemory(SponsoredCCTPInterface.SponsoredCCTPQuote memory q) internal pure returns (bytes32) {
        bytes32 hash1 = keccak256(
            abi.encode(
                q.sourceDomain,
                q.destinationDomain,
                q.mintRecipient,
                q.amount,
                q.burnToken,
                q.destinationCaller,
                q.maxFee,
                q.minFinalityThreshold
            )
        );

        bytes32 hash2 = keccak256(
            abi.encode(
                q.nonce,
                q.deadline,
                q.maxBpsToSponsor,
                q.maxUserSlippageBps,
                q.finalRecipient,
                q.finalToken,
                q.destinationDex,
                q.accountCreationMode,
                q.executionMode,
                keccak256(q.actionData)
            )
        );

        return keccak256(abi.encode(hash1, hash2));
    }

    function signMemory(
        Vm vm,
        uint256 pk,
        SponsoredCCTPInterface.SponsoredCCTPQuote memory q
    ) internal pure returns (bytes memory) {
        bytes32 digest = hashMemory(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}

/*
Direct path test (destination params are hardcoded in this script):
forge script script/mintburn/oft/TestDirectFlow.s.sol:TestDirectFlow \
  --sig "run(string,uint256)" \
  usdt0 1000000 \
  --rpc-url <srcChainRpc> --broadcast -vvvv
*/
contract TestDirectFlow is Script, Config {
    using AddressToBytes32 for address;

    // Hardcoded direct-flow settings (edit these as needed)
    address internal constant DST_HANDLER = 0xcB11aBbB2d5c4495047Fc8c85321a2083D3623A8;
    address internal constant FINAL_RECIPIENT = 0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D;
    address internal constant FINAL_TOKEN = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    uint256 internal constant MAX_BPS_TO_SPONSOR = 400;
    uint256 internal constant MAX_USER_SLIPPAGE_BPS = 500;
    uint8 internal constant EXECUTION_MODE = uint8(SponsoredExecutionModeInterface.ExecutionMode.ArbitraryActionsToEVM);
    // ActionData hardcoded route config:
    // swap USDT0 -> USDC, top up from donation box, approve+burn via SponsoredCCTPSrcPeriphery, then drain leftovers back.
    // Uniswap V3 SwapRouter02 on Polygon.
    address internal constant SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    // Set based on the available USDT0/USDC pool tier on Polygon.
    uint24 internal constant SWAP_POOL_FEE = 100;
    address internal constant DONATION_BOX = 0xa93cd36D1382d826854aAae31Ca58eEfA4650F03;
    address internal constant SPONSORED_CCTP_SRC_PERIPHERY = 0x7cfdccE4bBe329AFbAaC15072B62690DA8d6cA2d;
    uint32 internal constant CCTP_DESTINATION_DOMAIN = 6; // Base
    address internal constant CCTP_MINT_RECIPIENT = 0xd9DC78B969E9Efb1e54B625c33A21Aaf2509e6a1;
    address internal constant CCTP_DESTINATION_CALLER = 0xd9DC78B969E9Efb1e54B625c33A21Aaf2509e6a1;
    uint256 internal constant CCTP_MAX_FEE = 1000;
    uint32 internal constant CCTP_MIN_FINALITY_THRESHOLD = 1000;

    function run() external pure {
        revert("see header for supported signatures");
    }

    function run(string memory) external pure {
        revert("see header for supported signatures");
    }

    /// @notice Direct-path test with hardcoded destination parameters.
    function run(string memory tokenName, uint256 amountLD) external {
        _runDirect(
            tokenName,
            amountLD,
            DST_HANDLER,
            FINAL_RECIPIENT,
            FINAL_TOKEN,
            MAX_BPS_TO_SPONSOR,
            MAX_USER_SLIPPAGE_BPS,
            EXECUTION_MODE
        );
    }

    function _runDirect(
        string memory tokenName,
        uint256 amountLD,
        address dstHandler,
        address finalRecipient,
        address finalTokenOverride,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        uint8 executionMode
    ) internal {
        require(bytes(tokenName).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenName, ".toml"));
        _loadConfigAndForks(configPath, false);

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pk = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(pk);

        address srcPeriphery = config.get("src_periphery").toAddress();
        address token = config.get("token").toAddress();
        require(srcPeriphery != address(0), "src_periphery missing");
        require(token != address(0), "token missing");

        SponsoredOFTSrcPeriphery periphery = SponsoredOFTSrcPeriphery(srcPeriphery);
        require(periphery.signer() == deployer, "signer mismatch");

        uint32 srcEid = periphery.SRC_EID();
        address finalToken = finalTokenOverride == address(0) ? token : finalTokenOverride;

        // Useful guard before broadcasting
        bool hasDirectRole = DstOFTHandler(payable(dstHandler)).hasRole(
            DstOFTHandler(payable(dstHandler)).DIRECT_CALLER_ROLE(),
            srcPeriphery
        );
        require(hasDirectRole, "src periphery missing DIRECT_CALLER_ROLE on dst handler");
        address multicallHandler = DstOFTHandler(payable(dstHandler)).multicallHandler();
        require(multicallHandler != address(0), "multicall handler missing");
        address cctpPeriphery = SPONSORED_CCTP_SRC_PERIPHERY;
        require(cctpPeriphery != address(0), "cctp src periphery missing");
        uint256 maxSlippageTopUp = (amountLD * maxUserSlippageBps) / 10_000;
        address donationOwner = DonationBox(DONATION_BOX).owner();
        require(donationOwner == multicallHandler, "donationBox owner must be multicallHandler");

        SponsoredCCTPSrcPeriphery cctpSrcPeriphery = SponsoredCCTPSrcPeriphery(cctpPeriphery);
        require(cctpSrcPeriphery.signer() == deployer, "cctp signer mismatch");

        address finalTokenBase = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        bytes memory actionDataEmpty = abi.encode(new ArbitraryEVMFlowExecutor.CompressedCall[](0));

        SponsoredCCTPInterface.SponsoredCCTPQuote memory cctpQuote = SponsoredCCTPInterface.SponsoredCCTPQuote({
            sourceDomain: cctpSrcPeriphery.sourceDomain(),
            destinationDomain: CCTP_DESTINATION_DOMAIN,
            mintRecipient: CCTP_MINT_RECIPIENT.toBytes32(),
            amount: amountLD, // 1 USDC if amountLD is 1e6
            burnToken: finalToken.toBytes32(),
            destinationCaller: CCTP_DESTINATION_CALLER.toBytes32(),
            maxFee: CCTP_MAX_FEE,
            minFinalityThreshold: CCTP_MIN_FINALITY_THRESHOLD,
            nonce: keccak256(abi.encodePacked("cctp", block.timestamp, deployer, vm.getNonce(deployer))),
            deadline: block.timestamp + 1 hours,
            maxBpsToSponsor: maxBpsToSponsor,
            maxUserSlippageBps: maxUserSlippageBps,
            finalRecipient: finalRecipient.toBytes32(),
            finalToken: finalTokenBase.toBytes32(),
            destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
            accountCreationMode: 0,
            executionMode: uint8(SponsoredExecutionModeInterface.ExecutionMode.ArbitraryActionsToEVM),
            actionData: actionDataEmpty
        });
        bytes memory cctpSignature = DebugCCTPQuoteSignLib.signMemory(vm, pk, cctpQuote);
        bytes memory actionData = _buildActionData(
            token,
            finalToken,
            amountLD,
            maxUserSlippageBps,
            multicallHandler,
            cctpPeriphery,
            cctpQuote,
            cctpSignature
        );

        SponsoredOFTInterface.SignedQuoteParams memory signedParams = SponsoredOFTInterface.SignedQuoteParams({
            srcEid: srcEid,
            dstEid: srcEid, // required for depositDirect
            destinationHandler: dstHandler.toBytes32(),
            amountLD: amountLD,
            nonce: keccak256(abi.encodePacked(block.timestamp, deployer, vm.getNonce(deployer), amountLD)),
            deadline: block.timestamp + 1 hours,
            maxBpsToSponsor: maxBpsToSponsor,
            maxUserSlippageBps: maxUserSlippageBps,
            finalRecipient: finalRecipient.toBytes32(),
            finalToken: finalToken.toBytes32(),
            destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
            lzReceiveGasLimit: 200_000,
            lzComposeGasLimit: 300_000,
            maxOftFeeBps: 0,
            accountCreationMode: 0,
            executionMode: executionMode,
            actionData: actionData
        });

        SponsoredOFTInterface.UnsignedQuoteParams memory unsignedParams = SponsoredOFTInterface.UnsignedQuoteParams({
            refundRecipient: deployer
        });
        SponsoredOFTInterface.Quote memory quote = SponsoredOFTInterface.Quote({
            signedParams: signedParams,
            unsignedParams: unsignedParams
        });
        bytes memory signature = DebugDirectQuoteSignLib.signMemory(vm, pk, signedParams);

        console.log("=== Direct Flow Test ===");
        console.log("srcPeriphery:", srcPeriphery);
        console.log("token:", token);
        console.log("dstHandler:", dstHandler);
        console.log("finalRecipient:", finalRecipient);
        console.log("finalToken:", finalToken);
        console.log("amountLD:", amountLD);
        console.log("executionMode:", executionMode);
        console.log("maxBpsToSponsor:", maxBpsToSponsor);
        console.log("maxUserSlippageBps:", maxUserSlippageBps);
        console.log("swapRouter:", SWAP_ROUTER);
        console.log("donationBox:", DONATION_BOX);
        console.log("multicallHandler:", multicallHandler);
        console.log("donationOwner:", donationOwner);
        console.log("requiredTopupAmount:", maxSlippageTopUp);
        console.log("sponsoredCCTPSrcPeriphery:", cctpPeriphery);
        console.log("deployer:", deployer);

        vm.startBroadcast(pk);
        IERC20(token).approve(srcPeriphery, amountLD);
        periphery.depositDirect(quote, signature);
        vm.stopBroadcast();
    }

    function _buildActionData(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 maxUserSlippageBps,
        address multicallHandler,
        address cctpPeriphery,
        SponsoredCCTPInterface.SponsoredCCTPQuote memory cctpQuote,
        bytes memory cctpSignature
    ) internal view returns (bytes memory) {
        uint256 maxSlippageTopUp = (amountIn * maxUserSlippageBps) / 10_000;
        uint256 amountOutMinimum = (amountIn * (10_000 - maxUserSlippageBps)) / 10_000;

        ArbitraryEVMFlowExecutor.CompressedCall[] memory calls = new ArbitraryEVMFlowExecutor.CompressedCall[](6);

        // 1) Approve tokenIn to swap router (USDT0 -> router).
        calls[0] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: tokenIn,
            callData: abi.encodeWithSelector(IERC20.approve.selector, SWAP_ROUTER, amountIn)
        });

        // 2) Swap tokenIn -> tokenOut on Uniswap V3 and receive on multicall handler.
        calls[1] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: SWAP_ROUTER,
            callData: abi.encodeWithSelector(
                IUniswapV3RouterLike.exactInputSingle.selector,
                IUniswapV3RouterLike.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: SWAP_POOL_FEE,
                    recipient: multicallHandler,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMinimum,
                    sqrtPriceLimitX96: 0
                })
            )
        });

        // 3) Pull max slippage top-up from donation box to multicall handler.
        // DonationBox.withdraw transfers token to msg.sender (multicall handler).
        calls[2] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: DONATION_BOX,
            callData: abi.encodeCall(DonationBox.withdraw, (IERC20(tokenOut), maxSlippageTopUp))
        });

        // 4) Approve exact burn amount to SponsoredCCTPSrcPeriphery.
        calls[3] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: tokenOut,
            callData: abi.encodeWithSelector(IERC20.approve.selector, cctpPeriphery, cctpQuote.amount)
        });

        // 5) Call SponsoredCCTPSrcPeriphery.depositForBurn for 1:1 bridge leg.
        calls[4] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: cctpPeriphery,
            callData: abi.encodeCall(SponsoredCCTPSrcPeriphery.depositForBurn, (cctpQuote, cctpSignature))
        });

        // 6) Drain any remaining tokenOut back to donation box.
        calls[5] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: multicallHandler,
            callData: abi.encodeCall(MulticallHandler.drainLeftoverTokens, (tokenOut, payable(DONATION_BOX)))
        });

        return abi.encode(calls);
    }
}
