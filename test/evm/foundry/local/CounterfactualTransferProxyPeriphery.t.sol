// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Merkle } from "murky/Merkle.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import {
    CounterfactualDepositSpokePool,
    SpokePoolDepositParams,
    SpokePoolSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import {
    WithdrawImplementation,
    WithdrawParams
} from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { SpokePoolPeripheryInterface } from "../../../../contracts/interfaces/SpokePoolPeripheryInterface.sol";
import { TransferProxy } from "../../../../contracts/TransferProxy.sol";
import { MulticallHandler } from "../../../../contracts/handlers/MulticallHandler.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Mock SpokePoolPeriphery that records swapAndBridge calls and pulls tokens from caller.
 */
contract MockPeriphery {
    using SafeERC20 for IERC20;

    uint256 public callCount;
    address public lastDepositor;
    uint256 public lastSwapTokenAmount;
    uint256 public lastOutputAmount;
    address public lastSwapToken;
    address public lastSpokePool;
    uint256 public lastDestinationChainId;

    function swapAndBridge(SpokePoolPeripheryInterface.SwapAndDepositData calldata data) external payable {
        IERC20(data.swapToken).safeTransferFrom(msg.sender, address(this), data.swapTokenAmount);
        lastDepositor = data.depositData.depositor;
        lastSwapTokenAmount = data.swapTokenAmount;
        lastOutputAmount = data.depositData.outputAmount;
        lastSwapToken = data.swapToken;
        lastSpokePool = data.spokePool;
        lastDestinationChainId = data.depositData.destinationChainId;
        callCount++;
    }
}

/**
 * @title CounterfactualTransferProxyPeripheryTest
 * @notice PoC proving the flow: CounterfactualDepositSpokePool → TransferProxy → MulticallHandler → SpokePoolPeriphery.
 *
 * The existing CounterfactualDepositSpokePool can route through TransferProxy (same deposit() signature)
 * which forwards tokens + message to MulticallHandler, which then approves and calls SpokePoolPeriphery.
 *
 * Limitations demonstrated:
 *   - TransferProxy requires inputToken == outputToken and inputAmount == outputAmount
 *   - destinationChainId must be block.chainid (same-chain)
 *   - All swap parameters (exchange, routerCalldata, amounts) are baked into the merkle-committed message
 */
contract CounterfactualTransferProxyPeripheryTest is Test {
    Merkle public merkle;
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositSpokePool public spokePoolImpl;
    WithdrawImplementation public withdrawImpl;
    TransferProxy public transferProxy;
    MulticallHandler public multicallHandler;
    MockPeriphery public periphery;
    MintableERC20 public swapToken;
    address public realSpokePool;

    address public admin;
    address public user;
    address public relayer;
    uint256 public signerPrivateKey;
    address public signerAddr;

    // EIP-712 constants (must match CounterfactualDepositSpokePool)
    bytes32 constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
        );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("CounterfactualDepositSpokePool");
    bytes32 constant VERSION_HASH = keccak256("v1.0.0");

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        signerPrivateKey = 0xA11CE;
        signerAddr = vm.addr(signerPrivateKey);
        realSpokePool = makeAddr("realSpokePool");

        swapToken = new MintableERC20("USDC", "USDC", 6);
        transferProxy = new TransferProxy();
        multicallHandler = new MulticallHandler();
        periphery = new MockPeriphery();
        merkle = new Merkle();
        factory = new CounterfactualDepositFactory();
        dispatcher = new CounterfactualDeposit();
        // Key: spokePool is set to TransferProxy, not the real SpokePool
        spokePoolImpl = new CounterfactualDepositSpokePool(address(transferProxy), signerAddr, makeAddr("weth"));
        withdrawImpl = new WithdrawImplementation();

        swapToken.mint(user, 1000e6);
    }

    function _computeLeaf(address implementation, bytes memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))));
    }

    function _buildTreeAndPredict(
        bytes memory depositParamsEncoded,
        bytes32 salt
    ) internal returns (address predicted, bytes32 root, bytes32[] memory depositProof) {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), depositParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");
        root = merkle.getRoot(leaves);
        depositProof = merkle.getProof(leaves, 0);
        predicted = factory.predictDepositAddress(address(dispatcher), root, salt);
    }

    function _domainSeparator(address clone) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, clone));
    }

    function _sign(
        address clone,
        uint256 inputAmount,
        uint256 outputAmount,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                inputAmount,
                outputAmount,
                bytes32(0),
                uint32(0),
                quoteTimestamp,
                fillDeadline,
                signatureDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(clone), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice PoC: Full flow through TransferProxy → MulticallHandler → MockPeriphery.
     *
     * The message (MulticallHandler instructions) is pre-committed in the merkle leaf,
     * which means all swap parameters are fixed at address-generation time.
     */
    function testTransferProxyToMulticallHandlerToPeriphery() public {
        uint256 totalAmount = 100e6;
        uint256 executionFee = 1e6;
        uint256 swapAmount = totalAmount - executionFee; // 99e6 — what reaches MulticallHandler
        uint256 destinationChainId = 42161; // The real destination for the cross-chain bridge
        uint256 outputAmount = 95e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        // Build the MulticallHandler message. This is the key: we encode the approve + swapAndBridge
        // calls that MulticallHandler will execute after receiving tokens from TransferProxy.
        MulticallHandler.Call[] memory calls = new MulticallHandler.Call[](2);

        // Call 1: MulticallHandler approves MockPeriphery to pull swap tokens
        calls[0] = MulticallHandler.Call({
            target: address(swapToken),
            callData: abi.encodeCall(IERC20.approve, (address(periphery), swapAmount)),
            value: 0
        });

        // Call 2: MulticallHandler calls periphery.swapAndBridge
        SpokePoolPeripheryInterface.SwapAndDepositData memory swapData = SpokePoolPeripheryInterface
            .SwapAndDepositData({
                submissionFees: SpokePoolPeripheryInterface.Fees({ amount: 0, recipient: address(0) }),
                depositData: SpokePoolPeripheryInterface.BaseDepositData({
                    inputToken: address(swapToken), // post-swap token (in this PoC, same token)
                    outputToken: bytes32(uint256(uint160(address(swapToken)))),
                    outputAmount: outputAmount,
                    depositor: address(multicallHandler), // MulticallHandler is the msg.sender to periphery
                    recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                    destinationChainId: destinationChainId,
                    exclusiveRelayer: bytes32(0),
                    quoteTimestamp: uint32(block.timestamp),
                    fillDeadline: fillDeadline,
                    exclusivityParameter: 0,
                    message: ""
                }),
                swapToken: address(swapToken),
                exchange: makeAddr("exchange"),
                transferType: SpokePoolPeripheryInterface.TransferType.Approval,
                swapTokenAmount: swapAmount,
                minExpectedInputTokenAmount: swapAmount,
                routerCalldata: hex"aabbccdd",
                enableProportionalAdjustment: false,
                spokePool: realSpokePool,
                nonce: 0
            });
        calls[1] = MulticallHandler.Call({
            target: address(periphery),
            callData: abi.encodeCall(SpokePoolPeripheryInterface.swapAndBridge, (swapData)),
            value: 0
        });

        MulticallHandler.Instructions memory instructions = MulticallHandler.Instructions({
            calls: calls,
            fallbackRecipient: user // tokens returned to user if calls fail
        });
        bytes memory message = abi.encode(instructions);

        // Build SpokePoolDepositParams targeting TransferProxy.
        // Key constraints:
        //   - destinationChainId = block.chainid (TransferProxy enforces same-chain)
        //   - inputToken == outputToken (TransferProxy enforces)
        //   - The real cross-chain destination is buried inside the message
        bytes32 tokenAsBytes32 = bytes32(uint256(uint160(address(swapToken))));
        SpokePoolDepositParams memory params = SpokePoolDepositParams({
            destinationChainId: block.chainid, // Must be current chain for TransferProxy
            inputToken: tokenAsBytes32,
            outputToken: tokenAsBytes32, // Must match inputToken for TransferProxy
            recipient: bytes32(uint256(uint160(address(multicallHandler)))),
            message: message,
            stableExchangeRate: 1e18,
            maxFeeFixed: 2e6,
            maxFeeBps: 0,
            executionFee: executionFee
        });

        bytes32 salt = keccak256("transfer-proxy-poc");
        bytes memory paramsEncoded = abi.encode(params);
        (address depositAddress, bytes32 root, bytes32[] memory proof) = _buildTreeAndPredict(paramsEncoded, salt);

        // CounterfactualDepositSpokePool passes depositAmount as both inputAmount and outputAmount
        // in its call to SpokePool.deposit(). For TransferProxy, inputAmount must equal outputAmount.
        // Since the contract passes (depositAmount, sd.outputAmount), we set sd.outputAmount = depositAmount.
        uint256 depositAmount = totalAmount - executionFee; // = swapAmount
        bytes memory sig = _sign(
            depositAddress,
            totalAmount, // inputAmount
            depositAmount, // outputAmount = depositAmount to satisfy TransferProxy
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );
        bytes memory submitterData = abi.encode(
            SpokePoolSubmitterData({
                inputAmount: totalAmount,
                outputAmount: depositAmount, // Must equal depositAmount for TransferProxy
                exclusiveRelayer: bytes32(0),
                exclusivityDeadline: 0,
                executionFeeRecipient: relayer,
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: fillDeadline,
                signatureDeadline: uint32(block.timestamp) + 3600,
                signature: sig
            })
        );

        // Fund the predicted clone address
        vm.prank(user);
        swapToken.transfer(depositAddress, totalAmount);

        // Execute: deploy clone and trigger the full chain
        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (address(spokePoolImpl), paramsEncoded, submitterData, proof)
        );
        vm.prank(relayer);
        address deployed = factory.deployAndExecute(address(dispatcher), root, salt, executeCalldata);

        // Verify the full flow worked
        assertEq(deployed, depositAddress, "Deployed address matches prediction");
        assertEq(swapToken.balanceOf(depositAddress), 0, "Clone drained");
        assertEq(swapToken.balanceOf(relayer), executionFee, "Relayer got execution fee");
        assertEq(swapToken.balanceOf(address(multicallHandler)), 0, "MulticallHandler drained");

        // Verify MockPeriphery received the swapAndBridge call with correct params
        assertEq(periphery.callCount(), 1, "Periphery called once");
        assertEq(periphery.lastSwapTokenAmount(), swapAmount, "Periphery got swap amount");
        assertEq(periphery.lastOutputAmount(), outputAmount, "Correct output amount");
        assertEq(periphery.lastDestinationChainId(), destinationChainId, "Real destination chain");
        assertEq(periphery.lastDepositor(), address(multicallHandler), "Depositor is MulticallHandler");
        assertEq(swapToken.balanceOf(address(periphery)), swapAmount, "Periphery holds swap tokens");
    }
}
