// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import {
    CounterfactualDepositSpokePool,
    SpokePoolRouteParams,
    SpokePoolSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { WithdrawImplementation } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { RoutePolicyImmutableRoot } from "../../../../contracts/periphery/counterfactual/RoutePolicyImmutableRoot.sol";
import { deployRoutePolicy, rotateRoot } from "../utils/RoutePolicyTestHelper.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { CloneArgs } from "../../../../contracts/periphery/counterfactual/CounterfactualCloneArgs.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Mock SpokePool that records deposit parameters. Accepts native ETH when msg.value > 0.
 */
contract MockSpokePool {
    using SafeERC20 for IERC20;

    uint256 public callCount;
    bytes32 public lastDepositor;
    bytes32 public lastRecipient;
    bytes32 public lastInputToken;
    bytes32 public lastOutputToken;
    uint256 public lastInputAmount;
    uint256 public lastOutputAmount;
    uint256 public lastDestinationChainId;
    bytes32 public lastExclusiveRelayer;
    uint32 public lastQuoteTimestamp;
    uint32 public lastFillDeadline;
    uint32 public lastExclusivityDeadline;
    bytes public lastMessage;
    uint256 public lastMsgValue;

    function deposit(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable {
        if (msg.value > 0) {
            require(msg.value == inputAmount, "MockSpokePool: msg.value mismatch");
        } else {
            address tokenAddr = address(uint160(uint256(inputToken)));
            IERC20(tokenAddr).safeTransferFrom(msg.sender, address(this), inputAmount);
        }

        lastDepositor = depositor;
        lastRecipient = recipient;
        lastInputToken = inputToken;
        lastOutputToken = outputToken;
        lastInputAmount = inputAmount;
        lastOutputAmount = outputAmount;
        lastDestinationChainId = destinationChainId;
        lastExclusiveRelayer = exclusiveRelayer;
        lastQuoteTimestamp = quoteTimestamp;
        lastFillDeadline = fillDeadline;
        lastExclusivityDeadline = exclusivityDeadline;
        lastMessage = message;
        lastMsgValue = msg.value;
        callCount++;
    }
}

contract CounterfactualDepositSpokePoolTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositSpokePool public spokePoolImpl;
    WithdrawImplementation public withdrawImpl;
    RoutePolicyImmutableRoot public policy;
    MockSpokePool public spokePool;
    MintableERC20 public inputToken;
    address public weth;

    address public admin;
    address public user;
    address public relayer;
    address public policyOwner;
    uint256 public signerPrivateKey;
    address public signerAddr;
    bytes32 public recipient;

    bytes32 constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)"
        );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("CounterfactualDepositSpokePool");
    bytes32 constant VERSION_HASH = keccak256("v2.0.0");

    address constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 constant DESTINATION_CHAIN_ID = 42161;
    bytes32 public outputTokenBytes32;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        policyOwner = makeAddr("policyOwner");
        signerPrivateKey = 0xA11CE;
        signerAddr = vm.addr(signerPrivateKey);
        recipient = bytes32(uint256(uint160(makeAddr("recipient"))));

        inputToken = new MintableERC20("USDC", "USDC", 6);
        outputTokenBytes32 = bytes32(uint256(uint160(address(inputToken))));
        weth = makeAddr("weth");

        spokePool = new MockSpokePool();
        factory = new CounterfactualDepositFactory();
        withdrawImpl = new WithdrawImplementation();
        dispatcher = new CounterfactualDeposit();
        spokePoolImpl = new CounterfactualDepositSpokePool(address(spokePool), signerAddr, weth);
        policy = deployRoutePolicy(policyOwner, bytes32(0));

        inputToken.mint(user, 1000e6);
    }

    // --- Helpers ---

    function _cloneArgs(bytes32 outputToken_) internal view returns (CloneArgs memory) {
        return
            CloneArgs({
                outputToken: outputToken_,
                destinationChainId: DESTINATION_CHAIN_ID,
                recipient: recipient,
                admin: admin,
                routePolicyAddress: address(policy)
            });
    }

    function _defaultParams() internal view returns (SpokePoolRouteParams memory) {
        return
            SpokePoolRouteParams({
                inputToken: bytes32(uint256(uint160(address(inputToken)))),
                message: "",
                stableExchangeRate: 1e18,
                maxFeeFixed: 1e6,
                maxFeeBps: 500
            });
    }

    function _nativeParams() internal pure returns (SpokePoolRouteParams memory) {
        return
            SpokePoolRouteParams({
                inputToken: bytes32(uint256(uint160(NATIVE_ASSET))),
                message: "",
                stableExchangeRate: 1e18,
                maxFeeFixed: 0.01 ether,
                maxFeeBps: 500
            });
    }

    function _computeLeaf(
        address impl,
        bytes32 outputToken,
        uint256 destChainId,
        bytes memory routeParams
    ) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(impl, outputToken, destChainId, keccak256(routeParams)))));
    }

    function _setRoot(bytes32 outputToken_, bytes memory routeParams) internal returns (bytes32[] memory proof) {
        // For a single-leaf-of-interest tree, murky needs ≥2 leaves.
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _computeLeaf(address(spokePoolImpl), outputToken_, DESTINATION_CHAIN_ID, routeParams);
        leaves[1] = keccak256("padding");
        bytes32 root = _merkleRoot(leaves);
        proof = _merkleProof(leaves, 0);
        rotateRoot(policy, policyOwner, root);
    }

    function _merkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        // Simple 2-leaf sorted-pair merkle (matches OZ MerkleProof.verify).
        return _hashPair(leaves[0], leaves[1]);
    }

    function _merkleProof(bytes32[] memory leaves, uint256 idx) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = idx == 0 ? leaves[1] : leaves[0];
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _domainSeparator(address clone) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, clone));
    }

    struct SigInputs {
        address clone;
        bytes32 routeParamsHash;
        uint256 inputAmount;
        uint256 outputAmount;
        bytes32 exclusiveRelayer;
        uint32 exclusivityDeadline;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 signatureDeadline;
        uint256 executionFee;
        uint256 privateKey;
    }

    function _sign(SigInputs memory s) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                s.clone,
                s.routeParamsHash,
                s.inputAmount,
                s.outputAmount,
                s.exclusiveRelayer,
                s.exclusivityDeadline,
                s.quoteTimestamp,
                s.fillDeadline,
                s.signatureDeadline,
                s.executionFee
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(s.clone), structHash));
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(s.privateKey, digest);
        return abi.encodePacked(r, sigS, v);
    }

    struct ExecCtx {
        address clone;
        bytes routeParamsEncoded;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 executionFee;
        uint32 fillDeadline;
        uint32 signatureDeadline;
        bytes32 exclusiveRelayer;
        uint32 exclusivityDeadline;
        uint32 quoteTimestamp;
    }

    function _defaultExecCtx(address clone, bytes memory routeParamsEncoded) internal view returns (ExecCtx memory) {
        return
            ExecCtx({
                clone: clone,
                routeParamsEncoded: routeParamsEncoded,
                inputAmount: 100e6,
                outputAmount: 98e6,
                executionFee: 1e6,
                fillDeadline: uint32(block.timestamp) + 3600,
                signatureDeadline: uint32(block.timestamp) + 3600,
                exclusiveRelayer: bytes32(0),
                exclusivityDeadline: 0,
                quoteTimestamp: uint32(block.timestamp)
            });
    }

    function _buildSubmitterData(ExecCtx memory c, uint256 privKey) internal view returns (bytes memory) {
        bytes memory sig = _sign(
            SigInputs({
                clone: c.clone,
                routeParamsHash: keccak256(c.routeParamsEncoded),
                inputAmount: c.inputAmount,
                outputAmount: c.outputAmount,
                exclusiveRelayer: c.exclusiveRelayer,
                exclusivityDeadline: c.exclusivityDeadline,
                quoteTimestamp: c.quoteTimestamp,
                fillDeadline: c.fillDeadline,
                signatureDeadline: c.signatureDeadline,
                executionFee: c.executionFee,
                privateKey: privKey
            })
        );
        return
            abi.encode(
                SpokePoolSubmitterData({
                    inputAmount: c.inputAmount,
                    outputAmount: c.outputAmount,
                    exclusiveRelayer: c.exclusiveRelayer,
                    exclusivityDeadline: c.exclusivityDeadline,
                    executionFeeRecipient: relayer,
                    quoteTimestamp: c.quoteTimestamp,
                    fillDeadline: c.fillDeadline,
                    signatureDeadline: c.signatureDeadline,
                    executionFee: c.executionFee,
                    counterfactualSignature: sig
                })
            );
    }

    // --- Tests ---

    function testDeployAndExecute() public {
        bytes memory routeParamsEncoded = abi.encode(_defaultParams());
        bytes32[] memory proof = _setRoot(outputTokenBytes32, routeParamsEncoded);

        address clone = factory.deploy(address(dispatcher), _cloneArgs(outputTokenBytes32), keccak256("salt"));
        vm.prank(user);
        inputToken.transfer(clone, 100e6);

        ExecCtx memory ctx = _defaultExecCtx(clone, routeParamsEncoded);
        bytes memory submitterData = _buildSubmitterData(ctx, signerPrivateKey);

        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(outputTokenBytes32),
            address(spokePoolImpl),
            routeParamsEncoded,
            submitterData,
            proof
        );

        assertEq(inputToken.balanceOf(clone), 0);
        assertEq(inputToken.balanceOf(relayer), ctx.executionFee);
        assertEq(spokePool.lastInputAmount(), ctx.inputAmount - ctx.executionFee);
        assertEq(spokePool.lastDepositor(), bytes32(uint256(uint160(clone))));
        assertEq(spokePool.lastRecipient(), recipient);
    }

    function testInvalidSignatureReverts() public {
        bytes memory routeParamsEncoded = abi.encode(_defaultParams());
        bytes32[] memory proof = _setRoot(outputTokenBytes32, routeParamsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(outputTokenBytes32), keccak256("salt"));
        vm.prank(user);
        inputToken.transfer(clone, 100e6);

        ExecCtx memory ctx = _defaultExecCtx(clone, routeParamsEncoded);
        bytes memory submitterData = _buildSubmitterData(ctx, 0xBEEF); // wrong key

        vm.expectRevert(CounterfactualDepositSpokePool.InvalidSignature.selector);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(outputTokenBytes32),
            address(spokePoolImpl),
            routeParamsEncoded,
            submitterData,
            proof
        );
    }

    function testExpiredSignatureReverts() public {
        bytes memory routeParamsEncoded = abi.encode(_defaultParams());
        bytes32[] memory proof = _setRoot(outputTokenBytes32, routeParamsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(outputTokenBytes32), keccak256("salt"));
        vm.prank(user);
        inputToken.transfer(clone, 100e6);

        ExecCtx memory ctx = _defaultExecCtx(clone, routeParamsEncoded);
        ctx.signatureDeadline = uint32(block.timestamp) + 100;
        bytes memory submitterData = _buildSubmitterData(ctx, signerPrivateKey);

        vm.warp(block.timestamp + 101);

        vm.expectRevert(CounterfactualDepositSpokePool.SignatureExpired.selector);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(outputTokenBytes32),
            address(spokePoolImpl),
            routeParamsEncoded,
            submitterData,
            proof
        );
    }

    function testTotalFeeCapEnforced() public {
        bytes memory routeParamsEncoded = abi.encode(_defaultParams());
        bytes32[] memory proof = _setRoot(outputTokenBytes32, routeParamsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(outputTokenBytes32), keccak256("salt"));
        vm.prank(user);
        inputToken.transfer(clone, 100e6);

        // Drop outputAmount so the implicit relayer fee shoots past maxFeeFixed + maxFeeBps*input.
        ExecCtx memory ctx = _defaultExecCtx(clone, routeParamsEncoded);
        ctx.outputAmount = 90e6;
        bytes memory submitterData = _buildSubmitterData(ctx, signerPrivateKey);

        vm.expectRevert(CounterfactualDepositSpokePool.MaxFee.selector);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(outputTokenBytes32),
            address(spokePoolImpl),
            routeParamsEncoded,
            submitterData,
            proof
        );
    }

    function testCrossCloneReplayReverts() public {
        bytes memory routeParamsEncoded = abi.encode(_defaultParams());
        bytes32[] memory proof = _setRoot(outputTokenBytes32, routeParamsEncoded);
        address clone1 = factory.deploy(address(dispatcher), _cloneArgs(outputTokenBytes32), keccak256("salt-1"));

        // Second clone with different recipient → different argsHash → different address.
        CloneArgs memory args2 = _cloneArgs(outputTokenBytes32);
        args2.recipient = bytes32(uint256(uint160(makeAddr("other-recipient"))));
        address clone2 = factory.deploy(address(dispatcher), args2, keccak256("salt-2"));

        vm.prank(user);
        inputToken.transfer(clone1, 100e6);
        inputToken.mint(user, 100e6);
        vm.prank(user);
        inputToken.transfer(clone2, 100e6);

        // Sign for clone1.
        ExecCtx memory ctx = _defaultExecCtx(clone1, routeParamsEncoded);
        bytes memory submitterData = _buildSubmitterData(ctx, signerPrivateKey);

        // Works on clone1.
        ICounterfactualDeposit(clone1).execute(
            _cloneArgs(outputTokenBytes32),
            address(spokePoolImpl),
            routeParamsEncoded,
            submitterData,
            proof
        );

        // Same submitterData (signed for clone1) replayed against clone2 fails because the EIP-712
        // domain separator binds the signature to clone1's address.
        vm.expectRevert(CounterfactualDepositSpokePool.InvalidSignature.selector);
        ICounterfactualDeposit(clone2).execute(args2, address(spokePoolImpl), routeParamsEncoded, submitterData, proof);
    }

    function testNativeDeposit() public {
        bytes32 nativeOutput = bytes32(uint256(uint160(NATIVE_ASSET)));
        bytes memory routeParamsEncoded = abi.encode(_nativeParams());
        bytes32[] memory proof = _setRoot(nativeOutput, routeParamsEncoded);

        address clone = factory.deploy(address(dispatcher), _cloneArgs(nativeOutput), keccak256("native"));
        vm.deal(clone, 1 ether);

        ExecCtx memory ctx = _defaultExecCtx(clone, routeParamsEncoded);
        ctx.inputAmount = 1 ether;
        ctx.outputAmount = 0.99 ether;
        ctx.executionFee = 0.01 ether;
        bytes memory submitterData = _buildSubmitterData(ctx, signerPrivateKey);

        ICounterfactualDeposit(clone).execute(
            _cloneArgs(nativeOutput),
            address(spokePoolImpl),
            routeParamsEncoded,
            submitterData,
            proof
        );

        assertEq(clone.balance, 0);
        assertEq(relayer.balance, ctx.executionFee);
        assertEq(spokePool.lastInputAmount(), ctx.inputAmount - ctx.executionFee);
        assertEq(spokePool.lastMsgValue(), ctx.inputAmount - ctx.executionFee);
        // SpokePool sees WETH as inputToken for native deposits.
        assertEq(spokePool.lastInputToken(), bytes32(uint256(uint160(weth))));
    }

    function testZeroExecutionFee() public {
        bytes memory routeParamsEncoded = abi.encode(_defaultParams());
        bytes32[] memory proof = _setRoot(outputTokenBytes32, routeParamsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(outputTokenBytes32), keccak256("salt"));
        vm.prank(user);
        inputToken.transfer(clone, 100e6);

        ExecCtx memory ctx = _defaultExecCtx(clone, routeParamsEncoded);
        ctx.executionFee = 0;
        bytes memory submitterData = _buildSubmitterData(ctx, signerPrivateKey);

        ICounterfactualDeposit(clone).execute(
            _cloneArgs(outputTokenBytes32),
            address(spokePoolImpl),
            routeParamsEncoded,
            submitterData,
            proof
        );

        assertEq(inputToken.balanceOf(relayer), 0);
        assertEq(spokePool.lastInputAmount(), ctx.inputAmount);
    }

    function testAdminEscapeStillWorks() public {
        // Even with the SpokePool impl wired up and a non-zero policy root, the admin can
        // pull funds via the admin escape — bypasses any signature/proof.
        bytes memory routeParamsEncoded = abi.encode(_defaultParams());
        _setRoot(outputTokenBytes32, routeParamsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(outputTokenBytes32), keccak256("salt"));
        inputToken.mint(clone, 100e6);

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(outputTokenBytes32),
            address(withdrawImpl),
            "",
            abi.encode(address(inputToken), admin, uint256(100e6)),
            new bytes32[](0)
        );

        assertEq(inputToken.balanceOf(admin), 100e6);
    }
}
