// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { MockERC1271 } from "../../../../../contracts/test/MockERC1271.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ExpandedERC20 } from "../../../../../contracts/external/uma/core/contracts/common/implementation/ExpandedERC20.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../../../../../contracts/libraries/AddressConverters.sol";
import { V3SpokePoolInterface } from "../../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { SpokePoolInterface } from "../../../../../contracts/interfaces/SpokePoolInterface.sol";
import { AcrossMessageHandler } from "../../../../../contracts/interfaces/SpokePoolMessageHandler.sol";

contract MockAcrossMessageHandlerWithEvent is AcrossMessageHandler {
    event ReceivedAcrossMessage(address tokenSent, uint256 amount, address relayer, bytes message);

    function handleV3AcrossMessage(
        address tokenSent,
        uint256 amount,
        address relayer,
        bytes memory message
    ) external override {
        emit ReceivedAcrossMessage(tokenSent, amount, relayer, message);
    }
}

contract SpokePoolRelayTest is Test {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    MockSpokePool public spokePool;
    WETH9 public weth;
    ExpandedERC20 public erc20;
    ExpandedERC20 public destErc20;
    MockERC1271 public erc1271;

    address public owner;
    address public crossDomainAdmin;
    address public hubPool;
    uint256 public depositorPrivateKey;
    address public depositor;
    address public recipient;
    address public relayer;

    uint256 public constant AMOUNT_TO_SEED = 1500e18;
    uint256 public constant AMOUNT_TO_DEPOSIT = 100e18;
    uint256 public constant DESTINATION_CHAIN_ID = 1342;
    uint256 public constant ORIGIN_CHAIN_ID = 666;
    uint256 public constant REPAYMENT_CHAIN_ID = 777;
    uint256 public constant FIRST_DEPOSIT_ID = 0;

    // FillStatus enum values
    uint256 public constant FILL_STATUS_UNFILLED = 0;
    uint256 public constant FILL_STATUS_REQUESTED_SLOW_FILL = 1;
    uint256 public constant FILL_STATUS_FILLED = 2;

    // FillType enum values
    uint256 public constant FILL_TYPE_FAST_FILL = 0;
    uint256 public constant FILL_TYPE_REPLACED_SLOW_FILL = 1;
    uint256 public constant FILL_TYPE_SLOW_FILL = 2;

    event FilledRelay(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 repaymentChainId,
        uint256 indexed originChainId,
        uint256 indexed depositId,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes32 exclusiveRelayer,
        bytes32 indexed relayer,
        bytes32 depositor,
        bytes32 recipient,
        bytes32 messageHash,
        V3SpokePoolInterface.V3RelayExecutionEventInfo relayExecutionInfo
    );

    function setUp() public {
        owner = makeAddr("owner");
        crossDomainAdmin = makeAddr("crossDomainAdmin");
        hubPool = makeAddr("hubPool");
        depositorPrivateKey = 0x12345;
        depositor = vm.addr(depositorPrivateKey);
        recipient = makeAddr("recipient");
        relayer = makeAddr("relayer");

        weth = new WETH9();

        // Deploy ERC20 tokens
        erc20 = new ExpandedERC20("USD Coin", "USDC", 18);
        erc20.addMember(1, address(this)); // Minter role

        destErc20 = new ExpandedERC20("L2 USD Coin", "L2 USDC", 18);
        destErc20.addMember(1, address(this)); // Minter role

        // Deploy SpokePool via proxy
        vm.startPrank(owner);
        MockSpokePool implementation = new MockSpokePool(address(weth));
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(MockSpokePool.initialize, (0, crossDomainAdmin, hubPool))
            )
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(DESTINATION_CHAIN_ID);
        vm.stopPrank();

        // Deploy ERC1271 mock with depositor as owner
        erc1271 = new MockERC1271(depositor);

        // Seed depositor with tokens
        erc20.mint(depositor, AMOUNT_TO_SEED);
        vm.deal(depositor, AMOUNT_TO_SEED);
        vm.prank(depositor);
        weth.deposit{ value: AMOUNT_TO_SEED }();

        // Seed relayer with tokens
        destErc20.mint(relayer, AMOUNT_TO_SEED);
        vm.deal(relayer, AMOUNT_TO_SEED);
        vm.prank(relayer);
        weth.deposit{ value: AMOUNT_TO_SEED }();

        // Approve spokepool to spend tokens
        vm.startPrank(depositor);
        erc20.approve(address(spokePool), AMOUNT_TO_DEPOSIT * 10);
        weth.approve(address(spokePool), AMOUNT_TO_DEPOSIT * 10);
        vm.stopPrank();

        vm.startPrank(relayer);
        destErc20.approve(address(spokePool), AMOUNT_TO_DEPOSIT * 10);
        weth.approve(address(spokePool), AMOUNT_TO_DEPOSIT * 10);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createRelayData() internal view returns (V3SpokePoolInterface.V3RelayData memory) {
        uint32 fillDeadline = uint32(spokePool.getCurrentTime()) + 1000;
        return
            V3SpokePoolInterface.V3RelayData({
                depositor: depositor.toBytes32(),
                recipient: recipient.toBytes32(),
                exclusiveRelayer: relayer.toBytes32(),
                inputToken: address(erc20).toBytes32(),
                outputToken: address(destErc20).toBytes32(),
                inputAmount: AMOUNT_TO_DEPOSIT,
                outputAmount: AMOUNT_TO_DEPOSIT,
                originChainId: ORIGIN_CHAIN_ID,
                depositId: FIRST_DEPOSIT_ID,
                fillDeadline: fillDeadline,
                exclusivityDeadline: fillDeadline - 500,
                message: ""
            });
    }

    function _getRelayHash(
        V3SpokePoolInterface.V3RelayData memory relayData,
        uint256 destChainId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(relayData, destChainId));
    }

    function _getRelayExecutionParams(
        V3SpokePoolInterface.V3RelayData memory relayData,
        uint256 destChainId
    ) internal pure returns (V3SpokePoolInterface.V3RelayExecutionParams memory) {
        return
            V3SpokePoolInterface.V3RelayExecutionParams({
                relay: relayData,
                relayHash: _getRelayHash(relayData, destChainId),
                updatedOutputAmount: relayData.outputAmount,
                updatedRecipient: relayData.recipient,
                updatedMessage: relayData.message,
                repaymentChainId: REPAYMENT_CHAIN_ID
            });
    }

    function _hashNonEmptyMessage(bytes memory message) internal pure returns (bytes32) {
        return message.length > 0 ? keccak256(message) : bytes32(0);
    }

    function _getUpdatedV3DepositSignature(
        uint256 privateKey,
        uint256 depositId,
        uint256 originChainId,
        uint256 updatedOutputAmount,
        bytes32 updatedRecipient,
        bytes memory updatedMessage
    ) internal pure returns (bytes memory) {
        bytes32 UPDATE_DEPOSIT_DETAILS_HASH = keccak256(
            "UpdateDepositDetails(uint256 depositId,uint256 originChainId,uint256 updatedOutputAmount,bytes32 updatedRecipient,bytes updatedMessage)"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                UPDATE_DEPOSIT_DETAILS_HASH,
                depositId,
                originChainId,
                updatedOutputAmount,
                updatedRecipient,
                keccak256(updatedMessage)
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId)"),
                keccak256("ACROSS-V2"),
                keccak256("1.0.0"),
                originChainId
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                    _FILL_RELAY INTERNAL LOGIC TESTS
    //////////////////////////////////////////////////////////////*/

    function testDefaultStatusIsUnfilled() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );
        assertEq(spokePool.fillStatuses(relayExecution.relayHash), FILL_STATUS_UNFILLED);
    }

    function testRelayHashSamePreAndPostAddressToBytes32Upgrade() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.message = abi.encodePacked(keccak256("random"));

        // Create legacy relay data with addresses instead of bytes32
        V3SpokePoolInterface.V3RelayDataLegacy memory legacyRelayData = V3SpokePoolInterface.V3RelayDataLegacy({
            depositor: relayData.depositor.toAddress(),
            recipient: relayData.recipient.toAddress(),
            exclusiveRelayer: relayData.exclusiveRelayer.toAddress(),
            inputToken: relayData.inputToken.toAddress(),
            outputToken: relayData.outputToken.toAddress(),
            inputAmount: relayData.inputAmount,
            outputAmount: relayData.outputAmount,
            originChainId: relayData.originChainId,
            depositId: uint32(relayData.depositId),
            fillDeadline: relayData.fillDeadline,
            exclusivityDeadline: relayData.exclusivityDeadline,
            message: relayData.message
        });

        bytes32 newRelayHash = _getRelayHash(relayData, DESTINATION_CHAIN_ID);
        bytes32 oldRelayHash = keccak256(abi.encode(legacyRelayData, DESTINATION_CHAIN_ID));

        assertEq(newRelayHash, oldRelayHash);
    }

    function testExpiredFillDeadlineReverts() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.fillDeadline = 0; // Will always be less than SpokePool.currentTime

        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.ExpiredFillDeadline.selector);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);
    }

    function testRelayHashAlreadyMarkedFilled() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        // MockSpokePool.setFillStatus takes FillType, but since enum values align (Filled=2, SlowFill=2), this works
        spokePool.setFillStatus(relayExecution.relayHash, V3SpokePoolInterface.FillType.SlowFill);

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);
    }

    function testFastFillReplacingSpeedUpRequestEmitsCorrectFillType() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        // MockSpokePool.setFillStatus takes FillType, but since enum values align (RequestedSlowFill=1, ReplacedSlowFill=1), this works
        spokePool.setFillStatus(relayExecution.relayHash, V3SpokePoolInterface.FillType.ReplacedSlowFill);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit FilledRelay(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            relayExecution.repaymentChainId,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.toBytes32(),
            relayData.depositor,
            relayData.recipient,
            _hashNonEmptyMessage(relayData.message),
            V3SpokePoolInterface.V3RelayExecutionEventInfo({
                updatedRecipient: relayData.recipient,
                updatedMessageHash: _hashNonEmptyMessage(relayExecution.updatedMessage),
                updatedOutputAmount: relayExecution.updatedOutputAmount,
                fillType: V3SpokePoolInterface.FillType.ReplacedSlowFill
            })
        );
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);

        assertEq(spokePool.fillStatuses(relayExecution.relayHash), FILL_STATUS_FILLED);
    }

    function testSlowFillEmitsCorrectFillType() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        // Transfer tokens to spoke pool for slow fill
        vm.prank(relayer);
        destErc20.transfer(address(spokePool), relayExecution.updatedOutputAmount);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit FilledRelay(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            relayExecution.repaymentChainId,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.toBytes32(),
            relayData.depositor,
            relayData.recipient,
            _hashNonEmptyMessage(relayData.message),
            V3SpokePoolInterface.V3RelayExecutionEventInfo({
                updatedRecipient: relayData.recipient,
                updatedMessageHash: _hashNonEmptyMessage(relayExecution.updatedMessage),
                updatedOutputAmount: relayExecution.updatedOutputAmount,
                fillType: V3SpokePoolInterface.FillType.SlowFill
            })
        );
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), true);

        assertEq(spokePool.fillStatuses(relayExecution.relayHash), FILL_STATUS_FILLED);
    }

    function testFastFillEmitsCorrectFillType() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit FilledRelay(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            relayExecution.repaymentChainId,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.toBytes32(),
            relayData.depositor,
            relayData.recipient,
            _hashNonEmptyMessage(relayData.message),
            V3SpokePoolInterface.V3RelayExecutionEventInfo({
                updatedRecipient: relayData.recipient,
                updatedMessageHash: _hashNonEmptyMessage(relayExecution.updatedMessage),
                updatedOutputAmount: relayExecution.updatedOutputAmount,
                fillType: V3SpokePoolInterface.FillType.FastFill
            })
        );
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);

        assertEq(spokePool.fillStatuses(relayExecution.relayHash), FILL_STATUS_FILLED);
    }

    function testTransfersFundsEvenWhenMsgSenderIsRecipient() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.recipient = relayer.toBytes32(); // Set recipient == relayer

        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        uint256 relayerBalanceBefore = destErc20.balanceOf(relayer);

        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);

        // Balance should change (transfer still happens)
        assertEq(destErc20.balanceOf(relayer), relayerBalanceBefore - AMOUNT_TO_DEPOSIT + AMOUNT_TO_DEPOSIT);
    }

    function testSendsUpdatedOutputAmountToUpdatedRecipient() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        // Overwrite amount to send to be double the original amount
        relayExecution.updatedOutputAmount = AMOUNT_TO_DEPOSIT * 2;
        // Overwrite recipient to depositor which is not the same as the original recipient
        relayExecution.updatedRecipient = depositor.toBytes32();

        assertTrue(relayExecution.updatedRecipient != relayData.recipient);
        assertTrue(relayExecution.updatedOutputAmount != relayData.outputAmount);

        vm.prank(relayer);
        destErc20.approve(address(spokePool), relayExecution.updatedOutputAmount);

        uint256 depositorBalanceBefore = destErc20.balanceOf(depositor);

        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);

        assertEq(destErc20.balanceOf(depositor), depositorBalanceBefore + AMOUNT_TO_DEPOSIT * 2);
    }

    function testUnwrapsNativeTokenIfSendingToEOA() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.outputToken = address(weth).toBytes32();

        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        uint256 recipientEthBalanceBefore = recipient.balance;

        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);

        assertEq(recipient.balance, recipientEthBalanceBefore + relayExecution.updatedOutputAmount);
    }

    function testSlowFillsSendNativeTokenOutOfSpokePoolBalance() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.outputToken = address(weth).toBytes32();

        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        // Transfer WETH to spoke pool for slow fill
        vm.prank(relayer);
        weth.transfer(address(spokePool), relayExecution.updatedOutputAmount);

        uint256 initialSpokeBalance = weth.balanceOf(address(spokePool));
        uint256 recipientEthBalanceBefore = recipient.balance;

        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), true);

        assertEq(recipient.balance, recipientEthBalanceBefore + relayExecution.updatedOutputAmount);
        assertEq(weth.balanceOf(address(spokePool)), initialSpokeBalance - relayExecution.updatedOutputAmount);
    }

    function testSlowFillsSendNonNativeTokenOutOfSpokePoolBalance() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        // Transfer tokens to spoke pool for slow fill
        vm.prank(relayer);
        destErc20.transfer(address(spokePool), relayExecution.updatedOutputAmount);

        uint256 spokeBalanceBefore = destErc20.balanceOf(address(spokePool));

        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), true);

        assertEq(destErc20.balanceOf(address(spokePool)), spokeBalanceBefore - relayExecution.updatedOutputAmount);
    }

    function testCallsMessageHandlerIfRecipientIsContract() public {
        MockAcrossMessageHandlerWithEvent messageHandler = new MockAcrossMessageHandlerWithEvent();

        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.recipient = address(messageHandler).toBytes32();
        relayData.message = hex"1234";

        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );

        // Expect the message handler to be called with the correct parameters
        vm.expectEmit(true, true, true, true, address(messageHandler));
        emit MockAcrossMessageHandlerWithEvent.ReceivedAcrossMessage(
            relayData.outputToken.toAddress(),
            relayExecution.updatedOutputAmount,
            relayer,
            relayData.message
        );

        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);
    }

    /*//////////////////////////////////////////////////////////////
                        FILL_V3_RELAY TESTS
    //////////////////////////////////////////////////////////////*/

    function testFillsAreNotPaused() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        vm.prank(owner);
        spokePool.pauseFills(true);

        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.FillsArePaused.selector);
        spokePool.fillRelay(relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }

    function testFillRelayReentrancyProtected() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        bytes memory functionCalldata = abi.encodeCall(
            spokePool.fillRelay,
            (relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32())
        );

        vm.prank(relayer);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        spokePool.callback(functionCalldata);
    }

    function testMustBeExclusiveRelayerBeforeExclusivityDeadline() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.exclusiveRelayer = recipient.toBytes32(); // Different from relayer
        relayData.exclusivityDeadline = relayData.fillDeadline;

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.NotExclusiveRelayer.selector);
        spokePool.fillRelay(relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32());

        // Can send it after exclusivity deadline
        relayData.exclusivityDeadline = 0;
        vm.prank(relayer);
        spokePool.fillRelay(relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }

    function testFillRelayEmitsCorrectEvent() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit FilledRelay(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            REPAYMENT_CHAIN_ID,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.toBytes32(),
            relayData.depositor,
            relayData.recipient,
            _hashNonEmptyMessage(relayData.message),
            V3SpokePoolInterface.V3RelayExecutionEventInfo({
                updatedRecipient: relayData.recipient,
                updatedMessageHash: _hashNonEmptyMessage(relayData.message),
                updatedOutputAmount: relayData.outputAmount,
                fillType: V3SpokePoolInterface.FillType.FastFill
            })
        );
        spokePool.fillRelay(relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }

    function testLegacyFillV3RelayEmitsCorrectEvent() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        V3SpokePoolInterface.V3RelayDataLegacy memory legacyRelayData = V3SpokePoolInterface.V3RelayDataLegacy({
            depositor: relayData.depositor.toAddress(),
            recipient: relayData.recipient.toAddress(),
            exclusiveRelayer: relayData.exclusiveRelayer.toAddress(),
            inputToken: relayData.inputToken.toAddress(),
            outputToken: relayData.outputToken.toAddress(),
            inputAmount: relayData.inputAmount,
            outputAmount: relayData.outputAmount,
            originChainId: relayData.originChainId,
            depositId: uint32(relayData.depositId),
            fillDeadline: relayData.fillDeadline,
            exclusivityDeadline: relayData.exclusivityDeadline,
            message: relayData.message
        });

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit FilledRelay(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            REPAYMENT_CHAIN_ID,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.toBytes32(),
            relayData.depositor,
            relayData.recipient,
            _hashNonEmptyMessage(relayData.message),
            V3SpokePoolInterface.V3RelayExecutionEventInfo({
                updatedRecipient: relayData.recipient,
                updatedMessageHash: _hashNonEmptyMessage(relayData.message),
                updatedOutputAmount: relayData.outputAmount,
                fillType: V3SpokePoolInterface.FillType.FastFill
            })
        );
        spokePool.fillV3Relay(legacyRelayData, REPAYMENT_CHAIN_ID);
    }

    /*//////////////////////////////////////////////////////////////
                FILL_RELAY_WITH_UPDATED_DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function testFillRelayWithUpdatedDepositVerifiesSameSignatureAsSpeedUpDeposit() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.originChainId = spokePool.chainId(); // Use spoke pool chain ID

        uint256 updatedOutputAmount = relayData.outputAmount + 1;
        address updatedRecipient = makeAddr("updatedRecipient");
        bytes memory updatedMessage = hex"1234";

        vm.prank(relayer);
        destErc20.approve(address(spokePool), updatedOutputAmount);

        bytes memory signature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage
        );

        // Both should not revert
        vm.prank(relayer);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );

        vm.prank(depositor);
        spokePool.speedUpV3Deposit(
            depositor,
            relayData.depositId,
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage,
            signature
        );

        vm.prank(depositor);
        spokePool.speedUpDeposit(
            depositor.toBytes32(),
            relayData.depositId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );
    }

    function testFillRelayWithUpdatedDepositInAbsenceOfExclusivity() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.originChainId = spokePool.chainId();

        uint256 updatedOutputAmount = relayData.outputAmount + 1;
        address updatedRecipient = makeAddr("updatedRecipient");
        bytes memory updatedMessage = hex"1234";

        // Clock drift between spokes can mean exclusivityDeadline is in future even when no exclusivity was applied.
        spokePool.setCurrentTime(relayData.exclusivityDeadline - 1);

        vm.prank(relayer);
        destErc20.approve(address(spokePool), updatedOutputAmount);

        bytes memory signature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage
        );

        // Set exclusivityDeadline to 0 (no exclusivity)
        relayData.exclusivityDeadline = 0;

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit FilledRelay(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            REPAYMENT_CHAIN_ID,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.toBytes32(),
            relayData.depositor,
            relayData.recipient,
            _hashNonEmptyMessage(relayData.message),
            V3SpokePoolInterface.V3RelayExecutionEventInfo({
                updatedRecipient: updatedRecipient.toBytes32(),
                updatedMessageHash: _hashNonEmptyMessage(updatedMessage),
                updatedOutputAmount: updatedOutputAmount,
                fillType: V3SpokePoolInterface.FillType.FastFill
            })
        );
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );
    }

    function testFillRelayWithUpdatedDepositMustBeExclusiveRelayer() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.originChainId = spokePool.chainId();
        relayData.exclusiveRelayer = recipient.toBytes32(); // Different from relayer
        relayData.exclusivityDeadline = relayData.fillDeadline;

        uint256 updatedOutputAmount = relayData.outputAmount + 1;
        address updatedRecipient = makeAddr("updatedRecipient");
        bytes memory updatedMessage = hex"1234";

        bytes memory signature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage
        );

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.NotExclusiveRelayer.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );

        // Even if not exclusive relayer, can send it after exclusivity deadline
        relayData.exclusivityDeadline = 0;

        vm.prank(relayer);
        destErc20.approve(address(spokePool), updatedOutputAmount);

        vm.prank(relayer);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );
    }

    function testFillRelayWithUpdatedDepositHappyCase() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.originChainId = spokePool.chainId();

        uint256 updatedOutputAmount = relayData.outputAmount + 1;
        address updatedRecipient = makeAddr("updatedRecipient");
        bytes memory updatedMessage = hex"1234";

        vm.prank(relayer);
        destErc20.approve(address(spokePool), updatedOutputAmount);

        bytes memory signature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage
        );

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit FilledRelay(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            REPAYMENT_CHAIN_ID,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer.toBytes32(),
            relayData.depositor,
            relayData.recipient,
            _hashNonEmptyMessage(relayData.message),
            V3SpokePoolInterface.V3RelayExecutionEventInfo({
                updatedRecipient: updatedRecipient.toBytes32(),
                updatedMessageHash: _hashNonEmptyMessage(updatedMessage),
                updatedOutputAmount: updatedOutputAmount,
                fillType: V3SpokePoolInterface.FillType.FastFill
            })
        );
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );

        // Check fill status mapping is updated
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _getRelayExecutionParams(
            relayData,
            DESTINATION_CHAIN_ID
        );
        assertEq(spokePool.fillStatuses(relayExecution.relayHash), FILL_STATUS_FILLED);
    }

    function testFillRelayWithUpdatedDepositValidatesDepositorSignature() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.originChainId = spokePool.chainId();

        uint256 updatedOutputAmount = relayData.outputAmount + 1;
        address updatedRecipient = makeAddr("updatedRecipient");
        bytes memory updatedMessage = hex"1234";

        bytes memory signature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage
        );

        // Incorrect depositor
        V3SpokePoolInterface.V3RelayData memory badRelayData = relayData;
        badRelayData.depositor = relayer.toBytes32();

        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            badRelayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );

        // Incorrect signature for different deposit ID
        bytes memory otherSignature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            relayData.depositId + 1,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage
        );

        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            otherSignature
        );

        // Incorrect origin chain ID
        badRelayData = relayData;
        badRelayData.originChainId = relayData.originChainId + 1;

        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            badRelayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );

        // Incorrect deposit ID
        badRelayData = relayData;
        badRelayData.depositId = relayData.depositId + 1;

        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            badRelayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );

        // Incorrect updated output amount
        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount - 1,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );

        // Incorrect updated recipient
        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            makeAddr("wrongRecipient").toBytes32(),
            updatedMessage,
            signature
        );

        // Incorrect updated message (using wrong signature)
        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            abi.encodePacked(keccak256("random"))
        );
    }

    function testFillRelayWithUpdatedDepositValidatesERC1271Signature() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.originChainId = spokePool.chainId();
        relayData.depositor = address(erc1271).toBytes32(); // ERC1271 contract as depositor

        uint256 updatedOutputAmount = relayData.outputAmount + 1;
        address updatedRecipient = makeAddr("updatedRecipient");
        bytes memory updatedMessage = hex"1234";

        // The MockERC1271 contract returns true for isValidSignature if the signature was signed by the contract's
        // owner (depositor), so using the depositor's signature should succeed
        bytes memory correctSignature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage
        );

        // Using someone else's signature should fail
        uint256 relayerPrivateKey = 0x54321;
        bytes memory incorrectSignature = _getUpdatedV3DepositSignature(
            relayerPrivateKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage
        );

        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            incorrectSignature
        );

        vm.prank(relayer);
        destErc20.approve(address(spokePool), updatedOutputAmount);

        // Correct signature should work
        vm.prank(relayer);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            correctSignature
        );
    }

    function testCannotSendUpdatedFillAfterOriginalFill() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.originChainId = spokePool.chainId();

        uint256 updatedOutputAmount = relayData.outputAmount + 1;
        address updatedRecipient = makeAddr("updatedRecipient");
        bytes memory updatedMessage = hex"1234";

        bytes memory signature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage
        );

        // First fill the relay normally
        vm.prank(relayer);
        spokePool.fillRelay(relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32());

        // Then try to fill with updated deposit - should revert
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );
    }

    function testCannotSendOriginalFillAfterUpdatedFill() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.originChainId = spokePool.chainId();

        uint256 updatedOutputAmount = relayData.outputAmount + 1;
        address updatedRecipient = makeAddr("updatedRecipient");
        bytes memory updatedMessage = hex"1234";

        vm.prank(relayer);
        destErc20.approve(address(spokePool), updatedOutputAmount);

        bytes memory signature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage
        );

        // First fill with updated deposit
        vm.prank(relayer);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            signature
        );

        // Then try to fill normally - should revert
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.fillRelay(relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }
}
