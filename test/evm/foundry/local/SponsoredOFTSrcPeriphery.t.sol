// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";

import { SponsoredOFTSrcPeriphery } from "../../../../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";
import { Quote, SignedQuoteParams, UnsignedQuoteParams } from "../../../../contracts/periphery/mintburn/sponsored-oft/Structs.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";

import { MockERC20 } from "../../../../contracts/test/MockERC20.sol";
import { MockOFTMessenger } from "../../../../contracts/test/MockOFTMessenger.sol";
import { MockEndpoint } from "../../../../contracts/test/MockEndpoint.sol";

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { DebugQuoteSignLib } from "../../../../script/mintburn/oft/CreateSponsoredDeposit.s.sol";

contract SponsoredOFTSrcPeripheryTest is Test {
    using AddressToBytes32 for address;

    uint32 internal constant SRC_EID = 101;

    address internal owner;
    address internal user;
    uint256 internal signerPk;
    address internal signer;
    address internal refundRecipient;

    MockERC20 internal token;
    MockEndpoint internal endpoint;
    MockOFTMessenger internal oft;
    SponsoredOFTSrcPeriphery internal periphery;

    uint256 internal constant USER_INITIAL_BAL = 1_000_000 ether;
    uint256 internal constant SEND_AMOUNT = 1_000 ether;
    uint256 internal constant QUOTED_NATIVE_FEE = 0.01 ether;

    function setUp() public {
        owner = address(this);
        user = vm.addr(111);
        signerPk = 0xA11CE;
        signer = vm.addr(signerPk);
        refundRecipient = vm.addr(222);

        token = new MockERC20();
        endpoint = new MockEndpoint(SRC_EID);
        oft = new MockOFTMessenger(address(token));
        oft.setEndpoint(address(endpoint));
        oft.setFeesToReturn(QUOTED_NATIVE_FEE, 0);

        periphery = new SponsoredOFTSrcPeriphery(address(token), address(oft), SRC_EID, signer);

        // Fund user with tokens and ETH
        deal(address(token), user, USER_INITIAL_BAL, true);
        vm.deal(user, 100 ether);

        // Pre-approve the periphery to pull SEND_AMOUNT
        vm.startPrank(user);
        IERC20(address(token)).approve(address(periphery), type(uint256).max);
        vm.stopPrank();
    }

    // Helpers
    function createDefaultQuote(
        bytes32 nonce,
        uint256 deadline,
        address destHandlerAddr,
        address finalRecipientAddr,
        address finalTokenAddr
    ) internal view returns (Quote memory q) {
        SignedQuoteParams memory sp = SignedQuoteParams({
            srcEid: SRC_EID,
            dstEid: uint32(201),
            destinationHandler: destHandlerAddr.toBytes32(),
            amountLD: SEND_AMOUNT,
            nonce: nonce,
            deadline: deadline,
            maxBpsToSponsor: 500, // 5%
            finalRecipient: finalRecipientAddr.toBytes32(),
            finalToken: finalTokenAddr.toBytes32(),
            lzReceiveGasLimit: 500_000,
            lzComposeGasLimit: 500_000,
            executionMode: uint8(0), // DirectToCore
            actionData: ""
        });

        UnsignedQuoteParams memory up = UnsignedQuoteParams({
            refundRecipient: refundRecipient,
            maxUserSlippageBps: 300 // 3%
        });

        q = Quote({ signedParams: sp, unsignedParams: up });
    }

    function signQuote(uint256 pk, Quote memory q) internal view returns (bytes memory sig) {
        sig = DebugQuoteSignLib.signMemory(vm, pk, q.signedParams);
    }

    function testDepositHappyPath() public {
        bytes32 nonce = keccak256("q-1");
        uint256 deadline = block.timestamp + 1 days;
        address destHandler = address(0x1234);
        address finalRecipientAddr = address(0xBEEF);
        address finalTokenAddr = address(0xCAFE);

        Quote memory quote = createDefaultQuote(nonce, deadline, destHandler, finalRecipientAddr, finalTokenAddr);
        bytes memory signature = signQuote(signerPk, quote);

        uint256 extra = 0.123 ether;
        uint256 refundRecipientBalBefore = refundRecipient.balance;

        vm.prank(user);
        vm.expectEmit(address(periphery));
        emit SponsoredOFTSrcPeriphery.SponsoredOFTSend(
            nonce,
            user,
            finalRecipientAddr.toBytes32(),
            destHandler.toBytes32(),
            deadline,
            500,
            300,
            finalTokenAddr.toBytes32(),
            signature
        );
        periphery.deposit{ value: QUOTED_NATIVE_FEE + extra }(quote, signature);

        // Refund only the extra portion
        assertEq(refundRecipient.balance - refundRecipientBalBefore, extra, "unexpected refund amount");
        assertEq(address(periphery).balance, 0, "periphery should not retain ETH");

        // OFT was called with precise native fee as msg.value
        assertEq(oft.lastMsgValue(), QUOTED_NATIVE_FEE, "incorrect msg.value to OFT");
        assertEq(oft.sendCallCount(), 1, "send not called exactly once");

        // Validate send params
        (
            uint32 spDstEid,
            bytes32 spTo,
            uint256 spAmountLD,
            uint256 spMinAmountLD,
            bytes memory spExtraOptions,
            bytes memory spComposeMsg,
            bytes memory spOftCmd
        ) = oft.lastSendParam();
        spExtraOptions; // silence - structure validated implicitly by OFT quote/send success
        assertEq(spDstEid, quote.signedParams.dstEid, "dstEid mismatch");
        assertEq(spTo, quote.signedParams.destinationHandler, "destination handler mismatch");
        assertEq(spAmountLD, SEND_AMOUNT, "amountLD mismatch");
        assertEq(spMinAmountLD, SEND_AMOUNT, "minAmountLD should equal amountLD (no fee-in-token)");
        assertEq(spOftCmd.length, 0, "oftCmd must be empty");

        // Validate composeMsg encoding (layout from ComposeMsgCodec._encode)
        (
            bytes32 gotNonce,
            uint256 gotDeadline,
            uint256 gotMaxBpsToSponsor,
            uint256 gotMaxUserSlippageBps,
            bytes32 gotFinalRecipient,
            bytes32 gotFinalToken,
            uint8 gotExecutionMode,
            bytes memory gotActionData
        ) = abi.decode(spComposeMsg, (bytes32, uint256, uint256, uint256, bytes32, bytes32, uint8, bytes));

        assertEq(gotNonce, nonce, "nonce mismatch");
        assertEq(gotDeadline, deadline, "deadline mismatch");
        assertEq(gotMaxBpsToSponsor, 500, "maxBpsToSponsor mismatch");
        assertEq(gotMaxUserSlippageBps, 300, "maxUserSlippageBps mismatch");
        assertEq(gotFinalRecipient, finalRecipientAddr.toBytes32(), "finalRecipient mismatch");
        assertEq(gotFinalToken, finalTokenAddr.toBytes32(), "finalToken mismatch");
        assertEq(gotExecutionMode, 0, "executionMode mismatch");
        assertEq(keccak256(gotActionData), keccak256(""), "actionData mismatch");

        // ERC20 was pulled and approved
        assertEq(IERC20(address(token)).balanceOf(user), USER_INITIAL_BAL - SEND_AMOUNT, "user balance mismatch");
        assertEq(IERC20(address(token)).balanceOf(address(periphery)), SEND_AMOUNT, "periphery balance mismatch");
        assertEq(IERC20(address(token)).allowance(address(periphery), address(oft)), SEND_AMOUNT, "allowance mismatch");

        // Nonce is marked used
        // assertTrue(periphery.getMainStorage().usedNonces[nonce], "nonce should be marked used");
    }

    function testDepositRevertsOnInsufficientNativeFee() public {
        bytes32 nonce = keccak256("q-2");
        uint256 deadline = block.timestamp + 1 days;
        Quote memory quote = createDefaultQuote(nonce, deadline, address(0x1234), address(0xBEEF), address(0xCAFE));
        bytes memory signature = signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTSrcPeriphery.InsufficientNativeFee.selector);
        periphery.deposit{ value: QUOTED_NATIVE_FEE - 1 }(quote, signature);
    }

    function testDepositRevertsOnInvalidSignature() public {
        bytes32 nonce = keccak256("q-3");
        uint256 deadline = block.timestamp + 1 days;
        Quote memory quote = createDefaultQuote(nonce, deadline, address(0x9999), address(0x8888), address(0x7777));
        bytes memory signature = signQuote(signerPk, quote);

        // Corrupt the signature (flip 1 bit)
        signature[0] = bytes1(uint8(signature[0]) ^ 0x01);

        vm.prank(user);
        // ECDSA may revert with its own error for malformed signatures; accept any revert here
        vm.expectRevert();
        periphery.deposit{ value: QUOTED_NATIVE_FEE }(quote, signature);
    }

    function testDepositRevertsOnIncorrectSigner() public {
        // Produce a well-formed signature from a non-authorized key
        uint256 wrongPk = 0xB0B;
        address wrongSigner = vm.addr(wrongPk);
        vm.assume(wrongSigner != signer);

        bytes32 nonce = keccak256("q-3b");
        uint256 deadline = block.timestamp + 1 days;

        Quote memory quote = createDefaultQuote(nonce, deadline, address(0x1111), address(0x2222), address(0x3333));
        // Sign with wrong private key
        bytes memory signature = signQuote(wrongPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTSrcPeriphery.IncorrectSignature.selector);
        periphery.deposit{ value: QUOTED_NATIVE_FEE }(quote, signature);
    }

    function testDepositRevertsOnExpiredQuote() public {
        bytes32 nonce = keccak256("q-4");
        uint256 pastDeadline = block.timestamp - 1;
        Quote memory quote = createDefaultQuote(nonce, pastDeadline, address(0xA1), address(0xB2), address(0xC3));
        bytes memory signature = signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTSrcPeriphery.QuoteExpired.selector);
        periphery.deposit{ value: QUOTED_NATIVE_FEE }(quote, signature);
    }

    function testDepositRevertsOnNonceReuse() public {
        bytes32 nonce = keccak256("q-5");
        uint256 deadline = block.timestamp + 1 days;
        Quote memory quote = createDefaultQuote(nonce, deadline, address(0xD1), address(0xD2), address(0xD3));
        bytes memory signature = signQuote(signerPk, quote);

        vm.prank(user);
        periphery.deposit{ value: QUOTED_NATIVE_FEE }(quote, signature);

        // Try again with the same quote/nonce
        vm.prank(user);
        vm.expectRevert(SponsoredOFTSrcPeriphery.NonceAlreadyUsed.selector);
        periphery.deposit{ value: QUOTED_NATIVE_FEE }(quote, signature);
    }
}
