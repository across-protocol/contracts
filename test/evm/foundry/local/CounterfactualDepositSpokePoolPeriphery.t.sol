// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Merkle } from "murky/Merkle.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import {
    CounterfactualDepositSpokePoolPeriphery,
    SpokePoolPeripheryDepositParams,
    SpokePoolPeripherySubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePoolPeriphery.sol";
import {
    WithdrawImplementation,
    WithdrawParams
} from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { SpokePoolPeripheryInterface } from "../../../../contracts/interfaces/SpokePoolPeripheryInterface.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Mock SpokePoolPeriphery that records swapAndBridge parameters and pulls tokens.
 */
contract MockSpokePoolPeriphery {
    using SafeERC20 for IERC20;

    uint256 public callCount;

    // Recorded SwapAndDepositData fields
    uint256 public lastSubmissionFeeAmount;
    address public lastInputToken;
    bytes32 public lastOutputToken;
    uint256 public lastOutputAmount;
    address public lastDepositor;
    bytes32 public lastRecipient;
    uint256 public lastDestinationChainId;
    bytes32 public lastExclusiveRelayer;
    uint32 public lastQuoteTimestamp;
    uint32 public lastFillDeadline;
    uint32 public lastExclusivityParameter;
    bytes public lastMessage;
    address public lastSwapToken;
    address public lastExchange;
    SpokePoolPeripheryInterface.TransferType public lastTransferType;
    uint256 public lastSwapTokenAmount;
    uint256 public lastMinExpectedInputTokenAmount;
    bytes public lastRouterCalldata;
    bool public lastEnableProportionalAdjustment;
    address public lastSpokePool;
    uint256 public lastNonce;

    function swapAndBridge(SpokePoolPeripheryInterface.SwapAndDepositData calldata data) external payable {
        // Pull tokens from caller (mirrors real periphery behavior)
        IERC20(data.swapToken).safeTransferFrom(msg.sender, address(this), data.swapTokenAmount);

        lastSubmissionFeeAmount = data.submissionFees.amount;
        lastInputToken = data.depositData.inputToken;
        lastOutputToken = data.depositData.outputToken;
        lastOutputAmount = data.depositData.outputAmount;
        lastDepositor = data.depositData.depositor;
        lastRecipient = data.depositData.recipient;
        lastDestinationChainId = data.depositData.destinationChainId;
        lastExclusiveRelayer = data.depositData.exclusiveRelayer;
        lastQuoteTimestamp = data.depositData.quoteTimestamp;
        lastFillDeadline = data.depositData.fillDeadline;
        lastExclusivityParameter = data.depositData.exclusivityParameter;
        lastMessage = data.depositData.message;
        lastSwapToken = data.swapToken;
        lastExchange = data.exchange;
        lastTransferType = data.transferType;
        lastSwapTokenAmount = data.swapTokenAmount;
        lastMinExpectedInputTokenAmount = data.minExpectedInputTokenAmount;
        lastRouterCalldata = data.routerCalldata;
        lastEnableProportionalAdjustment = data.enableProportionalAdjustment;
        lastSpokePool = data.spokePool;
        lastNonce = data.nonce;
        callCount++;
    }
}

contract CounterfactualSpokePoolPeripheryDepositTest is Test {
    Merkle public merkle;
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositSpokePoolPeriphery public peripheryImpl;
    WithdrawImplementation public withdrawImpl;
    MockSpokePoolPeriphery public periphery;
    MintableERC20 public swapToken;
    address public spokePool;

    address public admin;
    address public user;
    address public relayer;
    uint256 public signerPrivateKey;
    address public signerAddr;

    SpokePoolPeripheryDepositParams internal defaultParams;

    // EIP-712 constants (must match contract)
    bytes32 constant EXECUTE_SWAP_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteSwapDeposit(uint256 swapTokenAmount,uint256 outputAmount,uint256 minExpectedInputTokenAmount,address exchange,uint8 transferType,bytes32 routerCalldataHash,bytes32 exclusiveRelayer,uint32 exclusivityParameter,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
        );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("CounterfactualDepositSpokePoolPeriphery");
    bytes32 constant VERSION_HASH = keccak256("v1.0.0");

    address constant DEFAULT_EXCHANGE = address(0xDEF1);
    bytes constant DEFAULT_ROUTER_CALLDATA = hex"aabbccdd";

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        signerPrivateKey = 0xA11CE;
        signerAddr = vm.addr(signerPrivateKey);
        spokePool = makeAddr("spokePool");

        swapToken = new MintableERC20("USDC", "USDC", 6);
        periphery = new MockSpokePoolPeriphery();
        merkle = new Merkle();
        factory = new CounterfactualDepositFactory();
        dispatcher = new CounterfactualDeposit();
        peripheryImpl = new CounterfactualDepositSpokePoolPeriphery(address(periphery), spokePool, signerAddr);
        withdrawImpl = new WithdrawImplementation();

        swapToken.mint(user, 1000e6);

        defaultParams = SpokePoolPeripheryDepositParams({
            destinationChainId: 42161,
            inputToken: bytes32(uint256(uint160(makeAddr("inputToken")))),
            outputToken: bytes32(uint256(uint160(makeAddr("outputToken")))),
            recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
            message: "",
            swapToken: address(swapToken),
            maxFeeFixed: 1e6,
            maxFeeBps: 500,
            executionFee: 1e6,
            enableProportionalAdjustment: false
        });
    }

    function _computeLeaf(address implementation, bytes memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))));
    }

    function _buildTreeAndDeploy(
        bytes memory depositParamsEncoded,
        bytes32 salt
    ) internal returns (address clone, bytes32[] memory depositProof) {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(peripheryImpl), depositParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        bytes32 root = merkle.getRoot(leaves);
        depositProof = merkle.getProof(leaves, 0);
        clone = factory.deploy(address(dispatcher), root, salt);
    }

    function _buildTreeAndPredict(
        bytes memory depositParamsEncoded,
        bytes32 salt
    ) internal returns (address predicted, bytes32 root, bytes32[] memory depositProof) {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(peripheryImpl), depositParamsEncoded);
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

    function _signExecuteSwapDeposit(
        address clone,
        uint256 swapTokenAmount,
        uint256 outputAmount,
        uint256 minExpectedInputTokenAmount,
        address exchange,
        SpokePoolPeripheryInterface.TransferType transferType,
        bytes memory routerCalldata,
        bytes32 exclusiveRelayer,
        uint32 exclusivityParameter,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_SWAP_DEPOSIT_TYPEHASH,
                swapTokenAmount,
                outputAmount,
                minExpectedInputTokenAmount,
                exchange,
                transferType,
                keccak256(routerCalldata),
                exclusiveRelayer,
                exclusivityParameter,
                quoteTimestamp,
                fillDeadline,
                signatureDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(clone), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _encodeSubmitterData(
        address clone,
        uint256 swapTokenAmount,
        uint256 outputAmount,
        uint256 minExpectedInputTokenAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityParameter,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes memory sig = _signExecuteSwapDeposit(
            clone,
            swapTokenAmount,
            outputAmount,
            minExpectedInputTokenAmount,
            DEFAULT_EXCHANGE,
            SpokePoolPeripheryInterface.TransferType.Approval,
            DEFAULT_ROUTER_CALLDATA,
            exclusiveRelayer,
            exclusivityParameter,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline
        );
        return
            abi.encode(
                SpokePoolPeripherySubmitterData({
                    swapTokenAmount: swapTokenAmount,
                    outputAmount: outputAmount,
                    minExpectedInputTokenAmount: minExpectedInputTokenAmount,
                    exchange: DEFAULT_EXCHANGE,
                    transferType: SpokePoolPeripheryInterface.TransferType.Approval,
                    routerCalldata: DEFAULT_ROUTER_CALLDATA,
                    exclusiveRelayer: exclusiveRelayer,
                    exclusivityParameter: exclusivityParameter,
                    executionFeeRecipient: relayer,
                    quoteTimestamp: quoteTimestamp,
                    fillDeadline: fillDeadline,
                    signatureDeadline: signatureDeadline,
                    signature: sig
                })
            );
    }

    function testDeployAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        uint256 swapTokenAmount = 100e6;
        uint256 outputAmount = 95e6;
        uint256 minExpected = 97e6;
        uint256 expectedSwapAmount = swapTokenAmount - defaultParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32 root, bytes32[] memory proof) = _buildTreeAndPredict(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
            depositAddress,
            swapTokenAmount,
            outputAmount,
            minExpected,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        swapToken.transfer(depositAddress, swapTokenAmount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (address(peripheryImpl), paramsEncoded, submitterData, proof)
        );

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(address(dispatcher), root, salt, executeCalldata);

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(swapToken.balanceOf(depositAddress), 0, "Clone should have no balance left");
        assertEq(swapToken.balanceOf(relayer), defaultParams.executionFee, "Relayer should receive execution fee");
        assertEq(periphery.lastSwapTokenAmount(), expectedSwapAmount, "Periphery should receive swap amount");
        assertEq(periphery.callCount(), 1, "Periphery should be called once");
    }

    function testPeripheryCalledWithCorrectParams() public {
        bytes32 salt = keccak256("test-salt");
        uint256 swapTokenAmount = 100e6;
        uint256 outputAmount = 95e6;
        uint256 minExpected = 97e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        bytes32 exclusiveRelayer = bytes32(uint256(uint160(relayer)));
        uint32 exclusivityParameter = 300;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
            depositAddress,
            swapTokenAmount,
            outputAmount,
            minExpected,
            exclusiveRelayer,
            exclusivityParameter,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        swapToken.transfer(depositAddress, swapTokenAmount);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(peripheryImpl), paramsEncoded, submitterData, proof);

        // Verify periphery was called with correct SwapAndDepositData
        assertEq(periphery.lastSubmissionFeeAmount(), 0, "Submission fees should be zero");
        assertEq(periphery.lastInputToken(), address(uint160(uint256(defaultParams.inputToken))));
        assertEq(periphery.lastOutputToken(), defaultParams.outputToken);
        assertEq(periphery.lastOutputAmount(), outputAmount);
        assertEq(periphery.lastDepositor(), depositAddress, "Depositor should be clone address");
        assertEq(periphery.lastRecipient(), defaultParams.recipient);
        assertEq(periphery.lastDestinationChainId(), defaultParams.destinationChainId);
        assertEq(periphery.lastExclusiveRelayer(), exclusiveRelayer);
        assertEq(periphery.lastQuoteTimestamp(), uint32(block.timestamp));
        assertEq(periphery.lastFillDeadline(), fillDeadline);
        assertEq(periphery.lastExclusivityParameter(), exclusivityParameter);
        assertEq(periphery.lastSwapToken(), address(swapToken));
        assertEq(periphery.lastExchange(), DEFAULT_EXCHANGE);
        assertEq(uint8(periphery.lastTransferType()), uint8(SpokePoolPeripheryInterface.TransferType.Approval));
        assertEq(periphery.lastMinExpectedInputTokenAmount(), minExpected);
        assertEq(periphery.lastRouterCalldata(), DEFAULT_ROUTER_CALLDATA);
        assertEq(periphery.lastEnableProportionalAdjustment(), false);
        assertEq(periphery.lastSpokePool(), spokePool);
        assertEq(periphery.lastNonce(), 0, "Nonce must be 0 for gasful swapAndBridge");
    }

    function testInvalidSignatureReverts() public {
        bytes32 salt = keccak256("test-salt");
        uint256 swapTokenAmount = 100e6;
        uint256 outputAmount = 95e6;
        uint256 minExpected = 97e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        uint32 signatureDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        // Sign with wrong key
        uint256 wrongKey = 0xBEEF;
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_SWAP_DEPOSIT_TYPEHASH,
                swapTokenAmount,
                outputAmount,
                minExpected,
                DEFAULT_EXCHANGE,
                SpokePoolPeripheryInterface.TransferType.Approval,
                keccak256(DEFAULT_ROUTER_CALLDATA),
                bytes32(0),
                uint32(0),
                uint32(block.timestamp),
                fillDeadline,
                signatureDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(depositAddress), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        bytes memory submitterData = abi.encode(
            SpokePoolPeripherySubmitterData({
                swapTokenAmount: swapTokenAmount,
                outputAmount: outputAmount,
                minExpectedInputTokenAmount: minExpected,
                exchange: DEFAULT_EXCHANGE,
                transferType: SpokePoolPeripheryInterface.TransferType.Approval,
                routerCalldata: DEFAULT_ROUTER_CALLDATA,
                exclusiveRelayer: bytes32(0),
                exclusivityParameter: 0,
                executionFeeRecipient: relayer,
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: fillDeadline,
                signatureDeadline: signatureDeadline,
                signature: abi.encodePacked(r, s, v)
            })
        );

        vm.prank(user);
        swapToken.transfer(depositAddress, swapTokenAmount);

        vm.expectRevert(CounterfactualDepositSpokePoolPeriphery.InvalidSignature.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(peripheryImpl), paramsEncoded, submitterData, proof);
    }

    function testExpiredSignatureReverts() public {
        bytes32 salt = keccak256("test-salt-expired");
        uint256 swapTokenAmount = 100e6;
        uint256 outputAmount = 95e6;
        uint256 minExpected = 97e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        uint32 signatureDeadline = uint32(block.timestamp) + 100;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
            depositAddress,
            swapTokenAmount,
            outputAmount,
            minExpected,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            signatureDeadline
        );

        vm.prank(user);
        swapToken.transfer(depositAddress, swapTokenAmount);

        vm.warp(block.timestamp + 101);

        vm.expectRevert(CounterfactualDepositSpokePoolPeriphery.SignatureExpired.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(peripheryImpl), paramsEncoded, submitterData, proof);
    }

    function testExcessiveExecutionFeeReverts() public {
        // Set execution fee higher than maxFeeFixed + maxFeeBps allows
        SpokePoolPeripheryDepositParams memory params = defaultParams;
        params.executionFee = 100e6; // Way too high
        params.maxFeeFixed = 1e6;
        params.maxFeeBps = 100; // 1%

        bytes32 salt = keccak256("test-salt-fee");
        uint256 swapTokenAmount = 200e6;
        uint256 outputAmount = 95e6;
        uint256 minExpected = 97e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(params);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
            depositAddress,
            swapTokenAmount,
            outputAmount,
            minExpected,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        swapToken.transfer(depositAddress, swapTokenAmount);

        vm.expectRevert(CounterfactualDepositSpokePoolPeriphery.MaxFee.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(peripheryImpl), paramsEncoded, submitterData, proof);
    }

    function testExecutionFeeAtMaxPasses() public {
        // executionFee = maxFeeFixed + maxFeeBps * swapTokenAmount / 10000
        // 1e6 = 1e6 + 500 * 0 / 10000 — this doesn't work. Let's use:
        // swapTokenAmount = 100e6, maxFeeFixed = 0, maxFeeBps = 100 (1%)
        // maxFee = 0 + 100 * 100e6 / 10000 = 1e6
        // executionFee = 1e6
        SpokePoolPeripheryDepositParams memory params = defaultParams;
        params.executionFee = 1e6;
        params.maxFeeFixed = 0;
        params.maxFeeBps = 100; // 1%

        bytes32 salt = keccak256("test-salt-max-fee");
        uint256 swapTokenAmount = 100e6;
        uint256 outputAmount = 95e6;
        uint256 minExpected = 97e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(params);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
            depositAddress,
            swapTokenAmount,
            outputAmount,
            minExpected,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        swapToken.transfer(depositAddress, swapTokenAmount);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(peripheryImpl), paramsEncoded, submitterData, proof);

        assertEq(periphery.callCount(), 1);
        assertEq(swapToken.balanceOf(relayer), params.executionFee);
    }

    function testProportionalAdjustmentPassthrough() public {
        SpokePoolPeripheryDepositParams memory params = defaultParams;
        params.enableProportionalAdjustment = true;

        bytes32 salt = keccak256("test-salt-proportional");
        uint256 swapTokenAmount = 100e6;
        uint256 outputAmount = 95e6;
        uint256 minExpected = 97e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(params);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
            depositAddress,
            swapTokenAmount,
            outputAmount,
            minExpected,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        swapToken.transfer(depositAddress, swapTokenAmount);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(peripheryImpl), paramsEncoded, submitterData, proof);

        assertEq(periphery.lastEnableProportionalAdjustment(), true);
    }

    function testZeroExecutionFee() public {
        SpokePoolPeripheryDepositParams memory params = defaultParams;
        params.executionFee = 0;

        bytes32 salt = keccak256("test-salt-zero-fee");
        uint256 swapTokenAmount = 100e6;
        uint256 outputAmount = 95e6;
        uint256 minExpected = 97e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(params);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
            depositAddress,
            swapTokenAmount,
            outputAmount,
            minExpected,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        swapToken.transfer(depositAddress, swapTokenAmount);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(peripheryImpl), paramsEncoded, submitterData, proof);

        assertEq(swapToken.balanceOf(relayer), 0, "No fee should be paid");
        assertEq(periphery.lastSwapTokenAmount(), swapTokenAmount, "Full amount should go to periphery");
    }
}
