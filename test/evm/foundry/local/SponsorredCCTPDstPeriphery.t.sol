// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test, console } from "forge-std/Test.sol";
import { SponsoredCCTPDstPeriphery } from "../../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPDstPeriphery.sol";
import { IHyperCoreFlowExecutor } from "../../../../contracts/test/interfaces/IHyperCoreFlowExecutor.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { IMessageTransmitterV2 } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../../../../contracts/libraries/AddressConverters.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { HyperCoreMockHelper } from "./HyperCoreMockHelper.sol";
import { BaseSimulatorTest } from "./external/hyper-evm-lib/test/BaseSimulatorTest.sol";
import { PrecompileLib } from "./external/hyper-evm-lib/src/PrecompileLib.sol";
import { CoreWriterLib } from "./external/hyper-evm-lib/src/CoreWriterLib.sol";
import { CoreSimulatorLib } from "./external/hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";

contract MockMessageTransmitter is IMessageTransmitterV2 {
    bool internal shouldSucceed = true;

    function setShouldSucceed(bool _shouldSucceed) external {
        shouldSucceed = _shouldSucceed;
    }

    function receiveMessage(bytes calldata, bytes calldata) external view override returns (bool) {
        return shouldSucceed;
    }
}

contract MockDonationBox {
    function withdraw(IERC20 token, uint256 amount) external {
        token.transfer(msg.sender, amount);
    }

    function mockTransfer(address token, uint256 amount) external {
        IERC20(token).transfer(msg.sender, amount);
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

contract SponsoredCCTPDstPeripheryTest is BaseSimulatorTest {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    SponsoredCCTPDstPeriphery public periphery;
    MockMessageTransmitter public messageTransmitter;
    MockDonationBox public donationBox;
    MockUSDC public usdc;

    address public signer;
    uint256 public signerPrivateKey;
    address public admin;
    // address public user;
    address public finalRecipient;
    address public multicallHandler;

    uint32 constant SOURCE_DOMAIN = 0;
    uint32 constant DESTINATION_DOMAIN = 1;
    uint32 constant CORE_INDEX = 0;
    uint32 constant MIN_FINALITY_THRESHOLD = 100;

    uint256 constant DEFAULT_AMOUNT = 1000e6; // 1000 USDC
    uint256 constant DEFAULT_MAX_FEE = 10e6; // 10 USDC
    uint256 constant FEE_EXECUTED = 5e6; // 5 USDC

    function setUp() public override {
        super.setUp();

        admin = makeAddr("admin");
        // user = makeAddr("user");
        finalRecipient = makeAddr("finalRecipient");
        multicallHandler = makeAddr("multicallHandler");

        // Create signer
        signerPrivateKey = 0x1234;
        signer = vm.addr(signerPrivateKey);

        // Deploy mock contracts
        messageTransmitter = new MockMessageTransmitter();
        donationBox = new MockDonationBox();
        usdc = MockUSDC(0xb88339CB7199b77E23DB6E890353E22632Ba630f);

        // Setup HyperCore precompile mocks using the helper
        hyperCore.forceAccountActivation(finalRecipient);

        // Deploy periphery
        vm.startPrank(admin);
        periphery = new SponsoredCCTPDstPeriphery(
            address(messageTransmitter),
            signer,
            address(donationBox),
            address(usdc),
            multicallHandler
        );

        IHyperCoreFlowExecutor(address(periphery)).setCoreTokenInfo(address(usdc), CORE_INDEX, true, 1e6, 1e6);
        vm.stopPrank();

        // Deal USDC to periphery for testing
        deal(address(usdc), address(periphery), 10000e6);
    }

    /// @dev Helper function to create a valid CCTP message
    function createCCTPMessage(
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote,
        uint256 feeExecuted
    ) internal view returns (bytes memory) {
        // (bytes32, uint256, uint256, uint256, bytes32, bytes32, uint8, bytes)
        // BurnMessage body
        bytes memory hookData = abi.encode(
            quote.nonce,
            quote.deadline,
            quote.maxBpsToSponsor,
            quote.maxUserSlippageBps,
            quote.finalRecipient,
            quote.finalToken,
            quote.executionMode,
            quote.actionData
        );

        bytes memory messageBody = abi.encodePacked(
            uint32(2), // version
            quote.burnToken, // burnToken
            quote.mintRecipient, // mintRecipient
            uint256(quote.amount), // amount (32 bytes)
            bytes32(0), // padding (32 bytes - for alignment)
            quote.maxFee, // maxFee (32 bytes)
            feeExecuted, // feeExecuted (32 bytes)
            uint256(0), // hookDataRecipient (32 bytes - not used)
            hookData // hookData
        );

        // CCTP Message format as per MessageV2
        bytes memory message = abi.encodePacked(
            uint32(2), // version
            quote.sourceDomain, // sourceDomain
            quote.destinationDomain, // destinationDomain
            bytes32(uint256(1)), // nonce (CCTP nonce)
            quote.burnToken, // sender (token messenger on source)
            bytes32(uint256(uint160(address(messageTransmitter)))), // recipient (token messenger on dest)
            quote.destinationCaller, // destinationCaller
            quote.minFinalityThreshold, // minFinalityThreshold
            uint32(0), // finalityThresholdExecuted
            messageBody // messageBody
        );

        return message;
    }

    /// @dev Helper function to sign a quote
    function signQuote(
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

    /// @dev Helper function to create a default valid quote
    function createDefaultQuote() internal view returns (SponsoredCCTPInterface.SponsoredCCTPQuote memory) {
        return
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: SOURCE_DOMAIN,
                destinationDomain: DESTINATION_DOMAIN,
                mintRecipient: bytes32(uint256(uint160(address(periphery)))),
                amount: DEFAULT_AMOUNT,
                burnToken: address(usdc).toBytes32(),
                destinationCaller: bytes32(0),
                maxFee: DEFAULT_MAX_FEE,
                minFinalityThreshold: MIN_FINALITY_THRESHOLD,
                nonce: keccak256("test-nonce-1"),
                deadline: block.timestamp + 1 hours,
                maxBpsToSponsor: 100, // 1%
                maxUserSlippageBps: 50, // 0.5%
                finalRecipient: finalRecipient.toBytes32(),
                finalToken: address(usdc).toBytes32(),
                executionMode: uint8(SponsoredCCTPInterface.ExecutionMode.DirectToCore),
                actionData: bytes("")
            });
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC MESSAGE VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveMessage_ValidQuote_Success() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        // Note: setUp already mocks HyperCore precompiles
        // The actual event emitted is SimpleTransferFlowCompleted from HyperCoreFlowExecutor
        periphery.receiveMessage(message, attestation, signature);

        // Verify nonce is marked as used
        assertTrue(periphery.usedNonces(quote.nonce));
    }

    function test_ReceiveMessage_InvalidSignature_FallsBackToUnsponsoredFlow() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();

        // Sign with wrong private key
        uint256 wrongPrivateKey = 0x5678;
        bytes memory wrongSignature = signQuote(quote, wrongPrivateKey);

        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        // Should not revert, but should process as unsponsored
        periphery.receiveMessage(message, attestation, wrongSignature);

        // Nonce should NOT be marked as used since signature was invalid
        assertFalse(periphery.usedNonces(quote.nonce));
    }

    function test_ReceiveMessage_ExpiredDeadline_FallsBackToUnsponsoredFlow() public {
        vm.warp(block.timestamp + 2 hours);
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        quote.deadline = block.timestamp - 1 hours; // Expired deadline

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        // Should not revert, but should process as unsponsored
        periphery.receiveMessage(message, attestation, signature);

        // Nonce should NOT be marked as used
        assertFalse(periphery.usedNonces(quote.nonce));
    }

    function test_ReceiveMessage_DeadlineWithinBuffer_Success() public {
        vm.warp(block.timestamp + 1 hours);
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();

        // Set deadline to 15 minutes ago (within 30 minute buffer)
        quote.deadline = block.timestamp - 15 minutes;

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        periphery.receiveMessage(message, attestation, signature);

        // Should be processed as valid since within buffer
        assertTrue(periphery.usedNonces(quote.nonce));
    }

    function test_ReceiveMessage_DeadlineOutsideBuffer_FallsBack() public {
        vm.warp(block.timestamp + 1 hours);
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();

        // Set deadline to 31 minutes ago (outside 30 minute buffer)
        quote.deadline = block.timestamp - 31 minutes;

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        periphery.receiveMessage(message, attestation, signature);

        // Should NOT be processed as valid
        assertFalse(periphery.usedNonces(quote.nonce));
    }

    function test_ReceiveMessage_ReplayAttack_SecondAttemptNotSponsored() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        // First call - should succeed
        periphery.receiveMessage(message, attestation, signature);
        assertTrue(periphery.usedNonces(quote.nonce));

        // Second call with same nonce - should process as unsponsored
        // (CCTP prevents actual replay, but this tests nonce checking)
        quote.deadline = block.timestamp + 2 hours; // Update deadline
        bytes memory newSignature = signQuote(quote, signerPrivateKey);
        bytes memory newMessage = createCCTPMessage(quote, FEE_EXECUTED);

        // This would fail at CCTP level in practice, but for testing our logic:
        messageTransmitter.setShouldSucceed(true);
        periphery.receiveMessage(newMessage, attestation, newSignature);

        // Nonce already used, so not considered valid
        assertTrue(periphery.usedNonces(quote.nonce));
    }

    /*//////////////////////////////////////////////////////////////
                        MESSAGE DECODING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MessageDecoding_InvalidMintRecipient_KeepsFundsInContract() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();

        // Set mint recipient to wrong address
        quote.mintRecipient = bytes32(uint256(uint160(address(0x1234))));

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        uint256 balanceBefore = usdc.balanceOf(address(periphery));

        // Should not revert, but message validation fails so funds stay in contract
        periphery.receiveMessage(message, attestation, signature);

        uint256 balanceAfter = usdc.balanceOf(address(periphery));
        assertEq(balanceAfter, balanceBefore);
    }

    function test_MessageDecoding_InvalidFinalRecipient_FailsValidation() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();

        // Set invalid final recipient (has upper bits set)
        quote.finalRecipient = bytes32(uint256(1) << 200);

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        // Should not revert, but should fail validation
        periphery.receiveMessage(message, attestation, signature);

        // Nonce should NOT be used since message validation failed
        assertFalse(periphery.usedNonces(quote.nonce));
    }

    function test_MessageDecoding_InvalidFinalToken_FailsValidation() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();

        // Set invalid final token (has upper bits set)
        quote.finalToken = bytes32(uint256(1) << 200);

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        // Should not revert, but should fail validation
        periphery.receiveMessage(message, attestation, signature);

        // Nonce should NOT be used
        assertFalse(periphery.usedNonces(quote.nonce));
    }

    function test_MessageDecoding_ExtractsCorrectQuoteData() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        quote.maxBpsToSponsor = 250; // 2.5%
        quote.maxUserSlippageBps = 100; // 1%

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        // Verify the message is processed successfully
        periphery.receiveMessage(message, attestation, signature);

        // Verify nonce is marked as used, confirming successful processing
        assertTrue(periphery.usedNonces(quote.nonce));
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION MODE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveMessage_DirectToCore_Success() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        quote.executionMode = uint8(SponsoredCCTPInterface.ExecutionMode.DirectToCore);

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        periphery.receiveMessage(message, attestation, signature);

        assertTrue(periphery.usedNonces(quote.nonce));
    }

    struct CompressedCall {
        address target;
        bytes callData;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetSigner_OnlyAdmin() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(admin);
        periphery.setSigner(newSigner);

        assertEq(periphery.signer(), newSigner);
    }

    function test_SetSigner_NotAdmin_Reverts() public {
        address newSigner = makeAddr("newSigner");

        vm.prank(user);
        vm.expectRevert();
        periphery.setSigner(newSigner);
    }

    function test_SetQuoteDeadlineBuffer_OnlyAdmin() public {
        uint256 newBuffer = 1 hours;

        vm.prank(admin);
        periphery.setQuoteDeadlineBuffer(newBuffer);

        assertEq(periphery.quoteDeadlineBuffer(), newBuffer);
    }

    function test_SetQuoteDeadlineBuffer_NotAdmin_Reverts() public {
        uint256 newBuffer = 1 hours;

        vm.prank(user);
        vm.expectRevert();
        periphery.setQuoteDeadlineBuffer(newBuffer);
    }

    function test_SetQuoteDeadlineBuffer_AffectsValidation() public {
        // Set buffer to 0
        vm.prank(admin);
        periphery.setQuoteDeadlineBuffer(0);

        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        quote.deadline = block.timestamp - 1; // 1 second ago

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        periphery.receiveMessage(message, attestation, signature);

        // Should NOT be processed as valid (no buffer)
        assertFalse(periphery.usedNonces(quote.nonce));
    }

    /*//////////////////////////////////////////////////////////////
                        SIGNATURE VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SignatureValidation_DifferentSigner_Fails() public {
        // Change signer
        address newSigner = makeAddr("newSigner");
        vm.prank(admin);
        periphery.setSigner(newSigner);

        // Create quote signed with old signer
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        periphery.receiveMessage(message, attestation, signature);

        // Should not be valid with different signer
        assertFalse(periphery.usedNonces(quote.nonce));
    }

    function test_SignatureValidation_ModifiedAmount_Fails() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        quote.amount = 1000e6;

        // Sign quote
        bytes memory signature = signQuote(quote, signerPrivateKey);

        // Modify amount in message
        quote.amount = 2000e6;
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        periphery.receiveMessage(message, attestation, signature);

        // Should fail validation
        assertFalse(periphery.usedNonces(quote.nonce));
    }

    function test_SignatureValidation_ModifiedRecipient_Fails() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        bytes memory signature = signQuote(quote, signerPrivateKey);

        // Modify final recipient
        quote.finalRecipient = makeAddr("attacker").toBytes32();
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        periphery.receiveMessage(message, attestation, signature);

        // Should fail validation
        assertFalse(periphery.usedNonces(quote.nonce));
    }

    function test_SignatureValidation_ModifiedActionData_Fails() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        quote.executionMode = uint8(SponsoredCCTPInterface.ExecutionMode.ArbitraryActionsToCore);

        // Original action data
        address[] memory targets = new address[](1);
        targets[0] = address(usdc);
        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSignature("transfer(address,uint256)", finalRecipient, 100e6);
        quote.actionData = abi.encode(targets, callDatas);

        // Sign original quote
        bytes memory signature = signQuote(quote, signerPrivateKey);

        // Modify action data
        callDatas[0] = abi.encodeWithSignature("transfer(address,uint256)", makeAddr("attacker"), 100e6);
        quote.actionData = abi.encode(targets, callDatas);

        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        periphery.receiveMessage(message, attestation, signature);

        // Should fail validation (actionData is hashed in signature)
        assertFalse(periphery.usedNonces(quote.nonce));
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReceiveMessage_ZeroAmount_HandledGracefully() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        quote.amount = 0;

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, 0);
        bytes memory attestation = bytes("mock-attestation");

        // Should not revert
        periphery.receiveMessage(message, attestation, signature);

        assertTrue(periphery.usedNonces(quote.nonce));
    }

    function test_ReceiveMessage_EmptyActionData_DirectToCore() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        quote.executionMode = uint8(SponsoredCCTPInterface.ExecutionMode.DirectToCore);
        quote.actionData = bytes("");

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        periphery.receiveMessage(message, attestation, signature);

        assertTrue(periphery.usedNonces(quote.nonce));
    }

    function test_ReceiveMessage_MultipleQuotesInSequence() public {
        // Test multiple different quotes in sequence
        for (uint256 i = 0; i < 5; i++) {
            SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
            quote.nonce = keccak256(abi.encodePacked("test-nonce", i));

            bytes memory signature = signQuote(quote, signerPrivateKey);
            bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
            bytes memory attestation = bytes("mock-attestation");

            periphery.receiveMessage(message, attestation, signature);

            assertTrue(periphery.usedNonces(quote.nonce));
        }
    }

    function test_View_UsedNonces() public {
        bytes32 testNonce = keccak256("test-view-nonce");
        assertFalse(periphery.usedNonces(testNonce));

        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = createDefaultQuote();
        quote.nonce = testNonce;

        bytes memory signature = signQuote(quote, signerPrivateKey);
        bytes memory message = createCCTPMessage(quote, FEE_EXECUTED);
        bytes memory attestation = bytes("mock-attestation");

        periphery.receiveMessage(message, attestation, signature);

        assertTrue(periphery.usedNonces(testNonce));
    }

    function test_View_ContractReferences() public {
        assertEq(address(periphery.cctpMessageTransmitter()), address(messageTransmitter));
        assertEq(periphery.signer(), signer);
        assertEq(periphery.quoteDeadlineBuffer(), 30 minutes);
        assertEq(address(IHyperCoreFlowExecutor(address(periphery)).donationBox()), address(donationBox));
    }
}
