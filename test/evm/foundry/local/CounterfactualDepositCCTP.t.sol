// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import {
    CounterfactualDepositCCTP,
    CCTPDepositParams,
    CCTPSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { WithdrawImplementation } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { RoutePolicy } from "../../../../contracts/periphery/counterfactual/RoutePolicy.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { CloneArgs } from "../../../../contracts/periphery/counterfactual/CounterfactualCloneArgs.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

contract MockSponsoredCCTPSrcPeriphery {
    using SafeERC20 for IERC20;

    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMaxFee;
    uint256 public callCount;
    bytes public lastPeripherySig;

    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory sig) external {
        address burnToken = address(uint160(uint256(quote.burnToken)));
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), quote.amount);
        lastAmount = quote.amount;
        lastNonce = quote.nonce;
        lastMaxFee = quote.maxFee;
        lastPeripherySig = sig;
        callCount++;
    }
}

contract CounterfactualDepositCCTPTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositCCTP public cctpImpl;
    WithdrawImplementation public withdrawImpl;
    RoutePolicy public policy;
    MockSponsoredCCTPSrcPeriphery public srcPeriphery;
    MintableERC20 public burnToken;

    address public withdrawUser;
    address public user;
    address public relayer;
    address public policyOwner;
    uint256 public signerPrivateKey;
    address public signerAddr;

    bytes32 public finalRecipient;
    uint32 public constant SOURCE_DOMAIN = 0;
    uint32 public constant DESTINATION_DOMAIN = 3;
    uint256 public constant DESTINATION_CHAIN_ID = 999;

    bytes32 constant EXECUTE_CCTP_TYPEHASH =
        keccak256(
            "ExecuteCCTP(address clone,bytes32 paramsHash,uint256 amount,uint256 executionFee,uint32 signatureDeadline)"
        );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("CounterfactualDepositCCTP");
    bytes32 constant VERSION_HASH = keccak256("v1.1.0");

    CCTPDepositParams internal defaultDepositParams;

    function setUp() public {
        withdrawUser = makeAddr("withdrawUser");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        policyOwner = makeAddr("policyOwner");
        signerPrivateKey = 0xA11CE;
        signerAddr = vm.addr(signerPrivateKey);
        finalRecipient = bytes32(uint256(uint160(makeAddr("finalRecipient"))));

        burnToken = new MintableERC20("USDC", "USDC", 6);

        srcPeriphery = new MockSponsoredCCTPSrcPeriphery();
        factory = new CounterfactualDepositFactory();
        withdrawImpl = new WithdrawImplementation();
        dispatcher = new CounterfactualDeposit(address(withdrawImpl));
        cctpImpl = new CounterfactualDepositCCTP(address(srcPeriphery), SOURCE_DOMAIN, signerAddr);
        policy = new RoutePolicy(policyOwner, bytes32(0));

        burnToken.mint(user, 1000e6);

        defaultDepositParams = CCTPDepositParams({
            destinationChainId: DESTINATION_CHAIN_ID,
            outputToken: bytes32(uint256(uint160(address(burnToken)))),
            destinationDomain: DESTINATION_DOMAIN,
            mintRecipient: bytes32(uint256(uint160(makeAddr("dstPeriphery")))),
            burnToken: bytes32(uint256(uint160(address(burnToken)))),
            destinationCaller: bytes32(uint256(uint160(makeAddr("bot")))),
            cctpMaxFeeBps: 100,
            minFinalityThreshold: 1000,
            maxBpsToSponsor: 500,
            maxUserSlippageBps: 50,
            destinationDex: 0,
            accountCreationMode: 0,
            executionMode: 0,
            actionData: "",
            maxExecutionFee: 1e6
        });
    }

    // --- Helpers ---

    function _cloneArgs() internal view returns (CloneArgs memory) {
        return
            CloneArgs({
                outputToken: bytes32(uint256(uint160(address(burnToken)))),
                destinationChainId: DESTINATION_CHAIN_ID,
                recipient: finalRecipient,
                withdrawUser: withdrawUser,
                routePolicyAddress: address(policy)
            });
    }

    function _computeLeaf(address impl, bytes memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(impl, keccak256(params)))));
    }

    function _setRoot(bytes memory params) internal returns (bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _computeLeaf(address(cctpImpl), params);
        leaves[1] = keccak256("padding");
        bytes32 a = leaves[0];
        bytes32 b = leaves[1];
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        proof = new bytes32[](1);
        proof[0] = leaves[1];
        vm.prank(policyOwner);
        policy.updateRoot(root);
    }

    function _domainSeparator(address clone) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, clone));
    }

    function _sign(
        address clone,
        bytes32 paramsHash,
        uint256 amount,
        uint256 executionFee,
        uint32 signatureDeadline,
        uint256 privKey
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_CCTP_TYPEHASH, clone, paramsHash, amount, executionFee, signatureDeadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(clone), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildSubmitterData(
        address clone,
        bytes memory paramsEncoded,
        uint256 amount,
        uint256 executionFee,
        bytes32 nonce,
        uint32 signatureDeadline,
        uint256 privKey
    ) internal view returns (bytes memory) {
        bytes memory sig = _sign(clone, keccak256(paramsEncoded), amount, executionFee, signatureDeadline, privKey);
        return
            abi.encode(
                CCTPSubmitterData({
                    amount: amount,
                    executionFeeRecipient: relayer,
                    nonce: nonce,
                    cctpDeadline: block.timestamp + 1 hours,
                    executionFee: executionFee,
                    signatureDeadline: signatureDeadline,
                    peripherySignature: "periphery-sig",
                    signature: sig
                })
            );
    }

    // --- Tests ---

    function testDeployAndExecute() public {
        bytes memory paramsEncoded = abi.encode(defaultDepositParams);
        bytes32[] memory proof = _setRoot(paramsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("salt"));

        uint256 amount = 100e6;
        uint256 executionFee = 1e6;

        vm.prank(user);
        burnToken.transfer(clone, amount);

        bytes memory submitterData = _buildSubmitterData(
            clone,
            paramsEncoded,
            amount,
            executionFee,
            keccak256("nonce"),
            uint32(block.timestamp) + 3600,
            signerPrivateKey
        );

        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(cctpImpl), paramsEncoded, submitterData, proof);

        assertEq(burnToken.balanceOf(clone), 0);
        assertEq(burnToken.balanceOf(relayer), executionFee);
        assertEq(srcPeriphery.lastAmount(), amount - executionFee);
        assertEq(srcPeriphery.callCount(), 1);
        assertEq(keccak256(srcPeriphery.lastPeripherySig()), keccak256(bytes("periphery-sig")));
    }

    function testInvalidSignatureReverts() public {
        bytes memory paramsEncoded = abi.encode(defaultDepositParams);
        bytes32[] memory proof = _setRoot(paramsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("salt"));

        vm.prank(user);
        burnToken.transfer(clone, 100e6);

        bytes memory submitterData = _buildSubmitterData(
            clone,
            paramsEncoded,
            100e6,
            1e6,
            keccak256("nonce"),
            uint32(block.timestamp) + 3600,
            0xBEEF // wrong key
        );

        vm.expectRevert(CounterfactualDepositCCTP.InvalidSignature.selector);
        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(cctpImpl), paramsEncoded, submitterData, proof);
    }

    function testExpiredSignatureReverts() public {
        bytes memory paramsEncoded = abi.encode(defaultDepositParams);
        bytes32[] memory proof = _setRoot(paramsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("salt"));

        vm.prank(user);
        burnToken.transfer(clone, 100e6);

        uint32 deadline = uint32(block.timestamp) + 100;
        bytes memory submitterData = _buildSubmitterData(
            clone,
            paramsEncoded,
            100e6,
            1e6,
            keccak256("nonce"),
            deadline,
            signerPrivateKey
        );

        vm.warp(block.timestamp + 101);

        vm.expectRevert(CounterfactualDepositCCTP.SignatureExpired.selector);
        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(cctpImpl), paramsEncoded, submitterData, proof);
    }

    function testMaxExecutionFeeEnforced() public {
        bytes memory paramsEncoded = abi.encode(defaultDepositParams);
        bytes32[] memory proof = _setRoot(paramsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("salt"));

        vm.prank(user);
        burnToken.transfer(clone, 100e6);

        bytes memory submitterData = _buildSubmitterData(
            clone,
            paramsEncoded,
            100e6,
            2e6, // > maxExecutionFee (1e6)
            keccak256("nonce"),
            uint32(block.timestamp) + 3600,
            signerPrivateKey
        );

        vm.expectRevert(CounterfactualDepositCCTP.MaxExecutionFee.selector);
        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(cctpImpl), paramsEncoded, submitterData, proof);
    }

    function testZeroExecutionFee() public {
        bytes memory paramsEncoded = abi.encode(defaultDepositParams);
        bytes32[] memory proof = _setRoot(paramsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("salt"));

        uint256 amount = 100e6;
        vm.prank(user);
        burnToken.transfer(clone, amount);

        bytes memory submitterData = _buildSubmitterData(
            clone,
            paramsEncoded,
            amount,
            0,
            keccak256("nonce"),
            uint32(block.timestamp) + 3600,
            signerPrivateKey
        );

        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(cctpImpl), paramsEncoded, submitterData, proof);

        assertEq(burnToken.balanceOf(relayer), 0);
        assertEq(srcPeriphery.lastAmount(), amount);
    }

    function testCrossCloneReplayReverts() public {
        bytes memory paramsEncoded = abi.encode(defaultDepositParams);
        bytes32[] memory proof = _setRoot(paramsEncoded);
        address clone1 = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("salt-1"));

        CloneArgs memory args2 = _cloneArgs();
        args2.recipient = bytes32(uint256(uint160(makeAddr("other-recipient"))));
        address clone2 = factory.deploy(address(dispatcher), args2, keccak256("salt-2"));

        vm.prank(user);
        burnToken.transfer(clone1, 100e6);
        burnToken.mint(user, 100e6);
        vm.prank(user);
        burnToken.transfer(clone2, 100e6);

        // Sign for clone1.
        bytes memory submitterData = _buildSubmitterData(
            clone1,
            paramsEncoded,
            100e6,
            1e6,
            keccak256("nonce"),
            uint32(block.timestamp) + 3600,
            signerPrivateKey
        );

        ICounterfactualDeposit(clone1).execute(_cloneArgs(), address(cctpImpl), paramsEncoded, submitterData, proof);

        // Replay on clone2 fails — EIP-712 domain separator binds to clone1.
        vm.expectRevert(CounterfactualDepositCCTP.InvalidSignature.selector);
        ICounterfactualDeposit(clone2).execute(args2, address(cctpImpl), paramsEncoded, submitterData, proof);
    }

    function testWithdrawEscape() public {
        bytes memory paramsEncoded = abi.encode(defaultDepositParams);
        _setRoot(paramsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("salt"));
        burnToken.mint(clone, 100e6);

        vm.prank(withdrawUser);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(burnToken), withdrawUser, uint256(100e6)),
            new bytes32[](0)
        );

        assertEq(burnToken.balanceOf(withdrawUser), 100e6);
    }

    function testCctpMaxFeeBpsCalculation() public {
        bytes memory paramsEncoded = abi.encode(defaultDepositParams);
        bytes32[] memory proof = _setRoot(paramsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("salt"));

        uint256 amount = 100e6;
        uint256 executionFee = 1e6;
        uint256 depositAmount = amount - executionFee;

        vm.prank(user);
        burnToken.transfer(clone, amount);

        bytes memory submitterData = _buildSubmitterData(
            clone,
            paramsEncoded,
            amount,
            executionFee,
            keccak256("nonce"),
            uint32(block.timestamp) + 3600,
            signerPrivateKey
        );

        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(cctpImpl), paramsEncoded, submitterData, proof);

        assertEq(srcPeriphery.lastMaxFee(), (depositAmount * 100) / 10_000);
    }
}
