// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { SponsoredOFTSrcPeriphery } from "../../../../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { SponsoredCCTPSrcPeriphery } from "../../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";
import { PermissionedMulticallHandler } from "../../../../contracts/handlers/PermissionedMulticallHandler.sol";
import { MulticallHandler } from "../../../../contracts/handlers/MulticallHandler.sol";
import { ITokenMessengerV2 } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { ComposeMsgCodec } from "../../../../contracts/periphery/mintburn/sponsored-oft/ComposeMsgCodec.sol";

import { MockERC20 } from "../../../../contracts/test/MockERC20.sol";
import { MockOFTMessenger } from "../../../../contracts/test/MockOFTMessenger.sol";
import { MockEndpoint } from "../../../../contracts/test/MockEndpoint.sol";
import { HyperCoreLib } from "../../../../contracts/libraries/HyperCoreLib.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { DebugQuoteSignLib } from "../../../../script/mintburn/oft/CreateSponsoredDeposit.s.sol";

contract MockDirectAcrossHandler {
    using ComposeMsgCodec for bytes;

    address public lastToken;
    uint256 public lastAmount;
    bytes public lastComposeMsg;
    uint256 public callCount;

    function executeDirect(address tokenSent, uint256 amountLD, bytes calldata composeMsg) external {
        callCount++;
        lastToken = tokenSent;
        lastAmount = amountLD;
        lastComposeMsg = composeMsg;
    }
}

contract MockDirectMulticallShim {
    using ComposeMsgCodec for bytes;
    PermissionedMulticallHandler public immutable handler;

    constructor(address _handler) {
        handler = PermissionedMulticallHandler(payable(_handler));
    }

    function executeDirect(address tokenSent, uint256 amountLD, bytes calldata composeMsg) external {
        bytes memory actionData = composeMsg._getActionData();
        IERC20(tokenSent).transfer(address(handler), amountLD);
        handler.handleV3AcrossMessage(tokenSent, amountLD, msg.sender, actionData);
    }
}

contract MockTokenMessengerV2WithHook is ITokenMessengerV2 {
    uint256 public depositForBurnWithHookCallCount;
    uint256 public lastAmount;
    uint32 public lastDestinationDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32 public lastMinFinalityThreshold;
    bytes public lastHookData;

    function depositForBurn(uint256, uint32, bytes32, address, bytes32, uint256, uint32) external pure {}

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        depositForBurnWithHookCallCount++;
        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastHookData = hookData;
    }
}

contract SponsoredOFTSrcPeripheryTest is Test {
    using AddressToBytes32 for address;
    using ComposeMsgCodec for bytes;

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
    MockDirectAcrossHandler internal directHandler;
    MockDirectMulticallShim internal directMulticallShim;
    PermissionedMulticallHandler internal permissionedMulticall;
    MockTokenMessengerV2WithHook internal cctpMessenger;
    SponsoredCCTPSrcPeriphery internal cctpSrcPeriphery;

    uint256 internal constant USER_INITIAL_BAL = 1_000_000 ether;
    uint256 internal constant SEND_AMOUNT = 1_000 ether;
    uint256 internal constant QUOTED_NATIVE_FEE = 0.01 ether;
    uint32 internal constant CCTP_SOURCE_DOMAIN = 0;
    uint32 internal constant CCTP_DESTINATION_DOMAIN = 10;
    uint32 internal constant CCTP_MIN_FINALITY = 1000;
    uint256 internal cctpSignerPk;
    address internal cctpSigner;

    function setUp() public {
        owner = address(this);
        user = vm.addr(111);
        signerPk = 0xA11CE;
        signer = vm.addr(signerPk);
        cctpSignerPk = 0xC0FFEE;
        cctpSigner = vm.addr(cctpSignerPk);
        refundRecipient = vm.addr(222);

        token = new MockERC20();
        endpoint = new MockEndpoint(SRC_EID);
        oft = new MockOFTMessenger(address(token));
        oft.setEndpoint(address(endpoint));
        oft.setFeesToReturn(QUOTED_NATIVE_FEE, 0);
        directHandler = new MockDirectAcrossHandler();
        permissionedMulticall = new PermissionedMulticallHandler(address(this));
        directMulticallShim = new MockDirectMulticallShim(address(permissionedMulticall));
        cctpMessenger = new MockTokenMessengerV2WithHook();
        cctpSrcPeriphery = new SponsoredCCTPSrcPeriphery(address(cctpMessenger), CCTP_SOURCE_DOMAIN, cctpSigner);

        periphery = new SponsoredOFTSrcPeriphery(address(token), address(oft), SRC_EID, signer);

        permissionedMulticall.grantRole(permissionedMulticall.WHITELISTED_CALLER_ROLE(), address(directMulticallShim));

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
    ) internal view returns (SponsoredOFTInterface.Quote memory q) {
        SponsoredOFTInterface.SignedQuoteParams memory sp = SponsoredOFTInterface.SignedQuoteParams({
            srcEid: SRC_EID,
            dstEid: uint32(201),
            destinationHandler: destHandlerAddr.toBytes32(),
            amountLD: SEND_AMOUNT,
            nonce: nonce,
            deadline: deadline,
            maxBpsToSponsor: 500, // 5%
            maxUserSlippageBps: 300, // 3%
            finalRecipient: finalRecipientAddr.toBytes32(),
            finalToken: finalTokenAddr.toBytes32(),
            destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
            lzReceiveGasLimit: 500_000,
            lzComposeGasLimit: 500_000,
            maxOftFeeBps: 0,
            accountCreationMode: uint8(0), // Standard
            executionMode: uint8(0), // DirectToCore
            actionData: ""
        });

        SponsoredOFTInterface.UnsignedQuoteParams memory up = SponsoredOFTInterface.UnsignedQuoteParams({
            refundRecipient: refundRecipient
        });

        q = SponsoredOFTInterface.Quote({ signedParams: sp, unsignedParams: up });
    }

    function signQuote(uint256 pk, SponsoredOFTInterface.Quote memory q) internal view returns (bytes memory sig) {
        sig = DebugQuoteSignLib.signMemory(vm, pk, q.signedParams);
    }

    function testDepositHappyPath() public {
        bytes32 nonce = keccak256("q-1");
        uint256 deadline = block.timestamp + 1 days;
        address destHandler = address(0x1234);
        address finalRecipientAddr = address(0xBEEF);
        address finalTokenAddr = address(0xCAFE);

        SponsoredOFTInterface.Quote memory quote = createDefaultQuote(
            nonce,
            deadline,
            destHandler,
            finalRecipientAddr,
            finalTokenAddr
        );
        bytes memory signature = signQuote(signerPk, quote);

        uint256 extra = 0.123 ether;
        uint256 refundRecipientBalBefore = refundRecipient.balance;

        vm.prank(user);
        vm.expectEmit(address(periphery));
        emit SponsoredOFTInterface.SponsoredOFTSend(
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
        assertEq(spMinAmountLD, SEND_AMOUNT, "minAmountLD should be SEND_AMOUNT (no dust loss)");
        assertEq(spOftCmd.length, 0, "oftCmd must be empty");

        // Validate composeMsg encoding (layout from ComposeMsgCodec._encode)
        assertEq(spComposeMsg._getNonce(), nonce, "nonce mismatch");
        assertEq(spComposeMsg._getAmountSD(), SEND_AMOUNT / 1e12, "amountSD mismatch");
        assertEq(spComposeMsg._getMaxBpsToSponsor(), 500, "maxBpsToSponsor mismatch");
        assertEq(spComposeMsg._getMaxUserSlippageBps(), 300, "maxUserSlippageBps mismatch");
        assertEq(spComposeMsg._getFinalRecipient(), finalRecipientAddr.toBytes32(), "finalRecipient mismatch");
        assertEq(spComposeMsg._getFinalToken(), finalTokenAddr.toBytes32(), "finalToken mismatch");
        assertEq(spComposeMsg._getDestinationDex(), HyperCoreLib.CORE_SPOT_DEX_ID, "destinationDex mismatch");
        assertEq(spComposeMsg._getAccountCreationMode(), 0, "accountCreationMode mismatch");
        assertEq(spComposeMsg._getExecutionMode(), 0, "executionMode mismatch");
        assertEq(keccak256(spComposeMsg._getActionData()), keccak256(""), "actionData mismatch");

        // ERC20 was pulled and approved
        assertEq(IERC20(address(token)).balanceOf(user), USER_INITIAL_BAL - SEND_AMOUNT, "user balance mismatch");
        assertEq(IERC20(address(token)).balanceOf(address(periphery)), SEND_AMOUNT, "periphery balance mismatch");
        assertEq(IERC20(address(token)).allowance(address(periphery), address(oft)), SEND_AMOUNT, "allowance mismatch");

        // Nonce is marked used
        // assertTrue(periphery.getMainStorage().usedNonces[nonce], "nonce should be marked used");
    }

    function testDepositDirectEndToEndWithPermissionedMulticallAndCCTP() public {
        bytes32 oftNonce = keccak256("oft-direct-e2e");
        bytes32 cctpNonce = keccak256("cctp-e2e");
        uint256 deadline = block.timestamp + 1 days;
        uint256 cctpAmount = 900 ether;
        uint256 leftover = SEND_AMOUNT - cctpAmount;

        SponsoredCCTPInterface.SponsoredCCTPQuote memory cctpQuote = SponsoredCCTPInterface.SponsoredCCTPQuote({
            sourceDomain: CCTP_SOURCE_DOMAIN,
            destinationDomain: CCTP_DESTINATION_DOMAIN,
            mintRecipient: address(0xBEEF).toBytes32(),
            amount: cctpAmount,
            burnToken: address(token).toBytes32(),
            destinationCaller: bytes32(0),
            maxFee: 10 ether,
            minFinalityThreshold: CCTP_MIN_FINALITY,
            nonce: cctpNonce,
            deadline: deadline,
            maxBpsToSponsor: 500,
            maxUserSlippageBps: 300,
            finalRecipient: address(0xCAFE).toBytes32(),
            finalToken: address(token).toBytes32(),
            destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
            accountCreationMode: uint8(0),
            executionMode: uint8(0),
            actionData: bytes("")
        });
        bytes memory cctpSig = _signCCTPQuote(cctpQuote, cctpSignerPk);

        MulticallHandler.Call[] memory calls = new MulticallHandler.Call[](2);
        calls[0] = MulticallHandler.Call({
            target: address(token),
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(cctpSrcPeriphery), cctpAmount),
            value: 0
        });
        calls[1] = MulticallHandler.Call({
            target: address(cctpSrcPeriphery),
            callData: abi.encodeCall(SponsoredCCTPSrcPeriphery.depositForBurn, (cctpQuote, cctpSig)),
            value: 0
        });
        MulticallHandler.Instructions memory instructions = MulticallHandler.Instructions({
            calls: calls,
            fallbackRecipient: user
        });

        SponsoredOFTInterface.Quote memory oftQuote = createDefaultQuote(
            oftNonce,
            deadline,
            address(directMulticallShim),
            address(0x1111),
            address(token)
        );
        oftQuote.signedParams.dstEid = SRC_EID;
        oftQuote.signedParams.amountLD = SEND_AMOUNT;
        oftQuote.signedParams.actionData = abi.encode(instructions);

        bytes memory oftSig = signQuote(signerPk, oftQuote);

        uint256 userBalBefore = IERC20(address(token)).balanceOf(user);
        vm.prank(user);
        periphery.depositDirect(oftQuote, oftSig);

        assertTrue(periphery.usedNonces(oftNonce), "OFT nonce not used");
        assertTrue(cctpSrcPeriphery.usedNonces(cctpNonce), "CCTP nonce not used");
        assertEq(cctpMessenger.depositForBurnWithHookCallCount(), 1, "CCTP call count mismatch");
        assertEq(cctpMessenger.lastAmount(), cctpAmount, "CCTP burn amount mismatch");
        assertEq(cctpMessenger.lastDestinationDomain(), CCTP_DESTINATION_DOMAIN, "CCTP dst domain mismatch");
        assertEq(cctpMessenger.lastBurnToken(), address(token), "CCTP burn token mismatch");
        assertEq(IERC20(address(token)).balanceOf(user), userBalBefore - cctpAmount, "user net spend mismatch");
        assertEq(leftover, IERC20(address(token)).balanceOf(user) - (userBalBefore - SEND_AMOUNT), "leftover mismatch");
        assertEq(IERC20(address(token)).balanceOf(address(permissionedMulticall)), 0, "handler retained funds");
    }

    function testDepositDirectHappyPath() public {
        bytes32 nonce = keccak256("q-direct-1");
        uint256 deadline = block.timestamp + 1 days;
        address finalRecipientAddr = address(0xBEEF);
        address finalTokenAddr = address(0xCAFE);

        SponsoredOFTInterface.Quote memory quote = createDefaultQuote(
            nonce,
            deadline,
            address(directHandler),
            finalRecipientAddr,
            finalTokenAddr
        );
        quote.signedParams.dstEid = SRC_EID;
        quote.signedParams.executionMode = uint8(2); // ArbitraryActionsToEVM
        quote.signedParams.actionData = abi.encode(bytes32("direct-message"));
        bytes memory signature = signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectEmit(address(periphery));
        emit SponsoredOFTInterface.SponsoredOFTDirectExecution(
            nonce,
            user,
            address(directHandler).toBytes32(),
            SEND_AMOUNT,
            signature
        );
        periphery.depositDirect(quote, signature);

        assertEq(
            IERC20(address(token)).balanceOf(address(directHandler)),
            SEND_AMOUNT,
            "handler token balance mismatch"
        );
        assertEq(directHandler.lastToken(), address(token), "token mismatch");
        assertEq(directHandler.lastAmount(), SEND_AMOUNT, "amount mismatch");
        assertEq(directHandler.callCount(), 1, "executeDirect not called");
        bytes memory composeMsg = directHandler.lastComposeMsg();
        assertEq(composeMsg._getNonce(), nonce, "compose nonce mismatch");
        assertEq(composeMsg._getFinalRecipient(), finalRecipientAddr.toBytes32(), "compose final recipient mismatch");
        assertEq(composeMsg._getFinalToken(), finalTokenAddr.toBytes32(), "compose final token mismatch");
        assertEq(
            keccak256(composeMsg._getActionData()),
            keccak256(quote.signedParams.actionData),
            "compose action mismatch"
        );
        assertTrue(periphery.usedNonces(nonce), "nonce should be marked used");
    }

    function testDepositDirectRevertsOnInvalidDirectDstEid() public {
        bytes32 nonce = keccak256("q-direct-2");
        uint256 deadline = block.timestamp + 1 days;
        SponsoredOFTInterface.Quote memory quote = createDefaultQuote(
            nonce,
            deadline,
            address(directHandler),
            address(0xBEEF),
            address(0xCAFE)
        );
        // keep cross-chain eid from default quote
        bytes memory signature = signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.InvalidDirectDstEid.selector);
        periphery.depositDirect(quote, signature);
    }

    function testDepositDirectRevertsOnInvalidDirectHandler() public {
        bytes32 nonce = keccak256("q-direct-3");
        uint256 deadline = block.timestamp + 1 days;
        address eoaHandler = vm.addr(999);
        SponsoredOFTInterface.Quote memory quote = createDefaultQuote(
            nonce,
            deadline,
            eoaHandler,
            address(0xBEEF),
            address(0xCAFE)
        );
        quote.signedParams.dstEid = SRC_EID;
        bytes memory signature = signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.InvalidDirectHandler.selector);
        periphery.depositDirect(quote, signature);
    }

    function testDepositRevertsOnInsufficientNativeFee() public {
        bytes32 nonce = keccak256("q-2");
        uint256 deadline = block.timestamp + 1 days;
        SponsoredOFTInterface.Quote memory quote = createDefaultQuote(
            nonce,
            deadline,
            address(0x1234),
            address(0xBEEF),
            address(0xCAFE)
        );
        bytes memory signature = signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.InsufficientNativeFee.selector);
        periphery.deposit{ value: QUOTED_NATIVE_FEE - 1 }(quote, signature);
    }

    function testDepositRevertsOnInvalidSignature() public {
        bytes32 nonce = keccak256("q-3");
        uint256 deadline = block.timestamp + 1 days;
        SponsoredOFTInterface.Quote memory quote = createDefaultQuote(
            nonce,
            deadline,
            address(0x9999),
            address(0x8888),
            address(0x7777)
        );
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

        SponsoredOFTInterface.Quote memory quote = createDefaultQuote(
            nonce,
            deadline,
            address(0x1111),
            address(0x2222),
            address(0x3333)
        );
        // Sign with wrong private key
        bytes memory signature = signQuote(wrongPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.IncorrectSignature.selector);
        periphery.deposit{ value: QUOTED_NATIVE_FEE }(quote, signature);
    }

    function testDepositRevertsOnExpiredQuote() public {
        bytes32 nonce = keccak256("q-4");
        uint256 pastDeadline = block.timestamp - 1;
        SponsoredOFTInterface.Quote memory quote = createDefaultQuote(
            nonce,
            pastDeadline,
            address(0xA1),
            address(0xB2),
            address(0xC3)
        );
        bytes memory signature = signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.QuoteExpired.selector);
        periphery.deposit{ value: QUOTED_NATIVE_FEE }(quote, signature);
    }

    function testDepositRevertsOnNonceReuse() public {
        bytes32 nonce = keccak256("q-5");
        uint256 deadline = block.timestamp + 1 days;
        SponsoredOFTInterface.Quote memory quote = createDefaultQuote(
            nonce,
            deadline,
            address(0xD1),
            address(0xD2),
            address(0xD3)
        );
        bytes memory signature = signQuote(signerPk, quote);

        vm.prank(user);
        periphery.deposit{ value: QUOTED_NATIVE_FEE }(quote, signature);

        // Try again with the same quote/nonce
        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.NonceAlreadyUsed.selector);
        periphery.deposit{ value: QUOTED_NATIVE_FEE }(quote, signature);
    }

    function _signCCTPQuote(
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
                quote.destinationDex,
                quote.accountCreationMode,
                quote.executionMode,
                keccak256(quote.actionData)
            )
        );
        bytes32 digest = keccak256(abi.encode(hash1, hash2));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
