// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";

// OFT imports
import { SponsoredOFTSrcPeriphery } from "../../../../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";
import { DstOFTHandler } from "../../../../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";
import { ComposeMsgCodec } from "../../../../contracts/periphery/mintburn/sponsored-oft/ComposeMsgCodec.sol";

// CCTP imports
import { SponsoredCCTPSrcPeriphery } from "../../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPSrcPeriphery.sol";
import { SponsoredCCTPDstPeriphery } from "../../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPDstPeriphery.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { SponsoredExecutionModeInterface } from "../../../../contracts/interfaces/SponsoredExecutionModeInterface.sol";
import { IMessageTransmitterV2 } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { IHyperCoreFlowExecutor } from "../../../../contracts/test/interfaces/IHyperCoreFlowExecutor.sol";

// Shared
import { AddressToBytes32, Bytes32ToAddress } from "../../../../contracts/libraries/AddressConverters.sol";
import { HyperCoreLib } from "../../../../contracts/libraries/HyperCoreLib.sol";
import { AccountCreationMode } from "../../../../contracts/periphery/mintburn/Structs.sol";
import { MockERC20 } from "../../../../contracts/test/MockERC20.sol";
import { MockOFTMessenger } from "../../../../contracts/test/MockOFTMessenger.sol";
import { MockEndpoint } from "../../../../contracts/test/MockEndpoint.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { DebugQuoteSignLib } from "../../../../script/mintburn/oft/CreateSponsoredDeposit.s.sol";

import { BaseSimulatorTest } from "./external/hyper-evm-lib/test/BaseSimulatorTest.sol";

// ──────────────────────────────────────────────────────────────────
// Mocks
// ──────────────────────────────────────────────────────────────────

contract MockMessageTransmitter is IMessageTransmitterV2 {
    function receiveMessage(bytes calldata, bytes calldata) external pure override returns (bool) {
        return true;
    }
}

contract MockDonationBox {
    function withdraw(IERC20 token, uint256 amount) external {
        token.transfer(msg.sender, amount);
    }
}

contract MockDirectDstOFTHandler {
    address public lastTokenSent;
    uint256 public lastAmountLD;
    bytes public lastComposeMsg;
    uint256 public callCount;

    function executeDirect(address tokenSent, uint256 amountLD, bytes calldata composeMsg) external {
        lastTokenSent = tokenSent;
        lastAmountLD = amountLD;
        lastComposeMsg = composeMsg;
        callCount++;
    }
}

contract MockUSDC is Test {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ──────────────────────────────────────────────────────────────────
// OFT Direct Flow Tests
// ──────────────────────────────────────────────────────────────────

contract OFTDirectFlowTest is Test {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    uint32 internal constant SRC_EID = 101;
    uint256 internal constant SEND_AMOUNT = 1_000 ether;

    address internal user;
    uint256 internal signerPk;
    address internal signer;

    address internal finalRecipient;

    MockERC20 internal token;
    MockEndpoint internal endpoint;
    MockOFTMessenger internal oft;
    MockDirectDstOFTHandler internal mockDstHandler;
    SponsoredOFTSrcPeriphery internal srcPeriphery;

    function setUp() public {
        user = makeAddr("user");
        signerPk = 0xA11CE;
        signer = vm.addr(signerPk);
        finalRecipient = makeAddr("finalRecipient");

        token = new MockERC20();
        endpoint = new MockEndpoint(SRC_EID);
        oft = new MockOFTMessenger(address(token));
        oft.setEndpoint(address(endpoint));
        oft.setFeesToReturn(0.01 ether, 0);

        srcPeriphery = new SponsoredOFTSrcPeriphery(address(token), address(oft), SRC_EID, signer);
        mockDstHandler = new MockDirectDstOFTHandler();

        // Fund user
        deal(address(token), user, 1_000_000 ether);
        vm.deal(user, 100 ether);
        vm.prank(user);
        IERC20(address(token)).approve(address(srcPeriphery), type(uint256).max);
    }

    function _createDirectQuote(bytes32 nonce) internal view returns (SponsoredOFTInterface.Quote memory) {
        return
            SponsoredOFTInterface.Quote({
                signedParams: SponsoredOFTInterface.SignedQuoteParams({
                    srcEid: SRC_EID,
                    dstEid: SRC_EID, // same chain
                    destinationHandler: address(mockDstHandler).toBytes32(),
                    amountLD: SEND_AMOUNT,
                    nonce: nonce,
                    deadline: block.timestamp + 1 days,
                    maxBpsToSponsor: 100,
                    maxUserSlippageBps: 50,
                    finalRecipient: finalRecipient.toBytes32(),
                    finalToken: address(token).toBytes32(),
                    destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
                    lzReceiveGasLimit: 500_000,
                    lzComposeGasLimit: 500_000,
                    maxOftFeeBps: 0,
                    accountCreationMode: uint8(0),
                    executionMode: uint8(0),
                    actionData: ""
                }),
                unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({ refundRecipient: user })
            });
    }

    function _signQuote(uint256 pk, SponsoredOFTInterface.Quote memory q) internal view returns (bytes memory) {
        return DebugQuoteSignLib.signMemory(vm, pk, q.signedParams);
    }

    function testDirectDeposit_HappyPath() public {
        SponsoredOFTInterface.Quote memory quote = _createDirectQuote(keccak256("direct-1"));
        bytes memory sig = _signQuote(signerPk, quote);

        uint256 userBalBefore = IERC20(address(token)).balanceOf(user);

        vm.prank(user);
        srcPeriphery.deposit(quote, sig);

        assertEq(IERC20(address(token)).balanceOf(user), userBalBefore - SEND_AMOUNT, "user balance");
        assertEq(IERC20(address(token)).balanceOf(address(mockDstHandler)), SEND_AMOUNT, "handler received tokens");
        assertTrue(srcPeriphery.usedNonces(quote.signedParams.nonce), "src nonce used");
        assertEq(mockDstHandler.callCount(), 1, "executeDirect called once");
        assertEq(mockDstHandler.lastTokenSent(), address(token), "correct token");
        assertEq(mockDstHandler.lastAmountLD(), SEND_AMOUNT, "correct amount");
    }

    function testDirectDeposit_EmitsEvent() public {
        SponsoredOFTInterface.Quote memory quote = _createDirectQuote(keccak256("direct-event"));
        bytes memory sig = _signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectEmit(address(srcPeriphery));
        emit SponsoredOFTInterface.SponsoredOFTDirectExecution(
            quote.signedParams.nonce,
            user,
            quote.signedParams.finalRecipient,
            quote.signedParams.destinationHandler,
            quote.signedParams.deadline,
            quote.signedParams.maxBpsToSponsor,
            quote.signedParams.maxUserSlippageBps,
            quote.signedParams.finalToken,
            sig
        );
        srcPeriphery.deposit(quote, sig);
    }

    function testDirectDeposit_RevertsWithMsgValue() public {
        SponsoredOFTInterface.Quote memory quote = _createDirectQuote(keccak256("direct-eth"));
        bytes memory sig = _signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.InvalidNativeFee.selector);
        srcPeriphery.deposit{ value: 1 wei }(quote, sig);
    }

    function testDirectDeposit_RevertsIfHandlerNotContract() public {
        SponsoredOFTInterface.Quote memory quote = _createDirectQuote(keccak256("direct-eoa"));
        quote.signedParams.destinationHandler = makeAddr("eoa").toBytes32();
        bytes memory sig = _signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.InvalidDirectHandler.selector);
        srcPeriphery.deposit(quote, sig);
    }

    function testDirectDeposit_RevertsOnNonceReuse() public {
        bytes32 nonce = keccak256("direct-reuse");
        SponsoredOFTInterface.Quote memory quote = _createDirectQuote(nonce);
        bytes memory sig = _signQuote(signerPk, quote);

        vm.prank(user);
        srcPeriphery.deposit(quote, sig);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.NonceAlreadyUsed.selector);
        srcPeriphery.deposit(quote, sig);
    }

    function testDirectDeposit_RevertsOnExpiredQuote() public {
        SponsoredOFTInterface.Quote memory quote = _createDirectQuote(keccak256("direct-expired"));
        quote.signedParams.deadline = block.timestamp - 1;
        bytes memory sig = _signQuote(signerPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.QuoteExpired.selector);
        srcPeriphery.deposit(quote, sig);
    }

    function testDirectDeposit_RevertsOnWrongSigner() public {
        SponsoredOFTInterface.Quote memory quote = _createDirectQuote(keccak256("direct-wrong-sig"));
        uint256 wrongPk = 0xB0B;
        bytes memory sig = _signQuote(wrongPk, quote);

        vm.prank(user);
        vm.expectRevert(SponsoredOFTInterface.IncorrectSignature.selector);
        srcPeriphery.deposit(quote, sig);
    }

    function testDirectDeposit_OFTNotCalled() public {
        SponsoredOFTInterface.Quote memory quote = _createDirectQuote(keccak256("direct-no-oft"));
        bytes memory sig = _signQuote(signerPk, quote);

        vm.prank(user);
        srcPeriphery.deposit(quote, sig);

        assertEq(oft.sendCallCount(), 0, "OFT should not be called for direct");
    }
}

// ──────────────────────────────────────────────────────────────────
// CCTP Direct Flow Tests
// ──────────────────────────────────────────────────────────────────

contract CCTPDirectFlowTest is BaseSimulatorTest {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    uint32 constant SOURCE_DOMAIN = 6;
    uint256 constant DEFAULT_AMOUNT = 1000e6;

    uint256 internal signerPk;
    address internal signer;
    address internal finalRecipient;

    MockUSDC internal usdc;
    MockMessageTransmitter internal messageTransmitter;
    MockDonationBox internal donationBox;
    SponsoredCCTPSrcPeriphery internal srcPeriphery;
    SponsoredCCTPDstPeriphery internal dstPeriphery;

    function setUp() public override {
        super.setUp();
        signerPk = 0x1234;
        signer = vm.addr(signerPk);
        finalRecipient = makeAddr("finalRecipient");
        hyperCore.forceAccountActivation(finalRecipient);

        usdc = MockUSDC(0xb88339CB7199b77E23DB6E890353E22632Ba630f);
        messageTransmitter = new MockMessageTransmitter();
        donationBox = new MockDonationBox();

        address multicallHandler = makeAddr("multicallHandler");

        // Deploy CCTP src periphery
        srcPeriphery = new SponsoredCCTPSrcPeriphery(
            address(messageTransmitter), // not used for direct, but required by constructor
            SOURCE_DOMAIN,
            signer
        );

        // Deploy CCTP dst periphery
        dstPeriphery = new SponsoredCCTPDstPeriphery(
            address(messageTransmitter),
            signer,
            address(donationBox),
            address(usdc),
            multicallHandler
        );

        // Grant DIRECT_CALLER_ROLE to srcPeriphery on dstPeriphery
        dstPeriphery.grantRole(dstPeriphery.DIRECT_CALLER_ROLE(), address(srcPeriphery));

        IHyperCoreFlowExecutor(address(dstPeriphery)).setCoreTokenInfo(address(usdc), 0, true, 1e6, 1e6);

        // Fund user with USDC
        deal(address(usdc), user, 100_000e6);
        vm.prank(user);
        IERC20(address(usdc)).approve(address(srcPeriphery), type(uint256).max);
    }

    function _createDirectQuote(
        bytes32 nonce
    ) internal view returns (SponsoredCCTPInterface.SponsoredCCTPQuote memory) {
        return
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: SOURCE_DOMAIN,
                destinationDomain: SOURCE_DOMAIN, // same chain
                mintRecipient: address(dstPeriphery).toBytes32(),
                amount: DEFAULT_AMOUNT,
                burnToken: address(usdc).toBytes32(),
                destinationCaller: bytes32(0),
                maxFee: 10e6,
                minFinalityThreshold: 100,
                nonce: nonce,
                deadline: block.timestamp + 1 hours,
                maxBpsToSponsor: 100,
                maxUserSlippageBps: 50,
                finalRecipient: finalRecipient.toBytes32(),
                finalToken: address(usdc).toBytes32(),
                destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
                accountCreationMode: uint8(AccountCreationMode.Standard),
                executionMode: uint8(SponsoredExecutionModeInterface.ExecutionMode.DirectToCore),
                actionData: ""
            });
    }

    function _signQuote(
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        uint256 pk
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
        bytes32 typedDataHash = keccak256(abi.encode(hash1, hash2));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, typedDataHash);
        return abi.encodePacked(r, s, v);
    }

    function testDirectDeposit_HappyPath() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = _createDirectQuote(keccak256("cctp-direct-1"));
        bytes memory sig = _signQuote(quote, signerPk);

        uint256 userBalBefore = usdc.balanceOf(user);

        vm.prank(user);
        srcPeriphery.depositForBurn(quote, sig);

        assertEq(usdc.balanceOf(user), userBalBefore - DEFAULT_AMOUNT, "user balance");
        assertTrue(srcPeriphery.usedNonces(quote.nonce), "src nonce used");
        assertTrue(dstPeriphery.usedNonces(quote.nonce), "dst nonce used");
    }

    function testDirectDeposit_EmitsEvent() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = _createDirectQuote(keccak256("cctp-direct-event"));
        bytes memory sig = _signQuote(quote, signerPk);

        vm.prank(user);
        vm.expectEmit(address(srcPeriphery));
        emit SponsoredCCTPInterface.SponsoredCCTPDirectExecution(
            quote.nonce,
            user,
            quote.finalRecipient,
            quote.deadline,
            quote.maxBpsToSponsor,
            quote.maxUserSlippageBps,
            quote.finalToken,
            quote.destinationDex,
            quote.accountCreationMode,
            sig
        );
        srcPeriphery.depositForBurn(quote, sig);
    }

    function testDirectDeposit_RevertsIfHandlerNotContract() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = _createDirectQuote(keccak256("cctp-direct-eoa"));
        quote.mintRecipient = makeAddr("eoa").toBytes32();
        bytes memory sig = _signQuote(quote, signerPk);

        vm.prank(user);
        vm.expectRevert(SponsoredCCTPInterface.InvalidDirectHandler.selector);
        srcPeriphery.depositForBurn(quote, sig);
    }

    function testDirectDeposit_RevertsOnNonceReuse() public {
        bytes32 nonce = keccak256("cctp-direct-reuse");
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = _createDirectQuote(nonce);
        bytes memory sig = _signQuote(quote, signerPk);

        vm.prank(user);
        srcPeriphery.depositForBurn(quote, sig);

        vm.prank(user);
        vm.expectRevert(SponsoredCCTPInterface.InvalidNonce.selector);
        srcPeriphery.depositForBurn(quote, sig);
    }

    function testDirectDeposit_RevertsOnExpiredQuote() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = _createDirectQuote(keccak256("cctp-expired"));
        quote.deadline = block.timestamp - 1;
        bytes memory sig = _signQuote(quote, signerPk);

        vm.prank(user);
        vm.expectRevert(SponsoredCCTPInterface.InvalidDeadline.selector);
        srcPeriphery.depositForBurn(quote, sig);
    }

    function testDirectDeposit_RevertsOnWrongSigner() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = _createDirectQuote(keccak256("cctp-wrong-sig"));
        uint256 wrongPk = 0x5678;
        bytes memory sig = _signQuote(quote, wrongPk);

        vm.prank(user);
        vm.expectRevert(SponsoredCCTPInterface.InvalidSignature.selector);
        srcPeriphery.depositForBurn(quote, sig);
    }

    function testDirectReceiveMessage_RevertsWithoutRole() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = _createDirectQuote(keccak256("cctp-no-role"));
        bytes memory sig = _signQuote(quote, signerPk);

        // Fund the dstPeriphery so authorizeFundedFlow doesn't fail
        deal(address(usdc), address(dstPeriphery), DEFAULT_AMOUNT);

        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert();
        dstPeriphery.directReceiveMessage(quote);
    }

    function testDirectReceiveMessage_RevertsOnInvalidBurnToken() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = _createDirectQuote(keccak256("cctp-bad-token"));
        quote.burnToken = makeAddr("wrongToken").toBytes32();
        bytes memory sig = _signQuote(quote, signerPk);

        // Fund and grant role
        deal(address(usdc), address(dstPeriphery), DEFAULT_AMOUNT);
        dstPeriphery.grantRole(dstPeriphery.DIRECT_CALLER_ROLE(), address(this));

        vm.expectRevert(SponsoredCCTPInterface.InvalidBurnToken.selector);
        dstPeriphery.directReceiveMessage(quote);
    }
}
