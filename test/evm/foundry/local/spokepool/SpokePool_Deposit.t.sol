// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ExpandedERC20 } from "../../../../../contracts/external/uma/core/contracts/common/implementation/ExpandedERC20.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../../../../../contracts/libraries/AddressConverters.sol";
import { V3SpokePoolInterface } from "../../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { SpokePoolInterface } from "../../../../../contracts/interfaces/SpokePoolInterface.sol";

contract SpokePoolDepositTest is Test {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    MockSpokePool public spokePool;
    WETH9 public weth;
    ExpandedERC20 public erc20;

    address public owner;
    address public crossDomainAdmin;
    address public hubPool;
    uint256 public depositorPrivateKey;
    address public depositor;
    address public recipient;

    uint256 public constant AMOUNT_TO_SEED = 1500e18;
    uint256 public constant AMOUNT_TO_DEPOSIT = 100e18;
    uint256 public constant DESTINATION_CHAIN_ID = 1342;
    uint256 public constant ORIGIN_CHAIN_ID = 666;
    uint32 public constant MAX_EXCLUSIVITY_OFFSET_SECONDS = 31_536_000; // 1 year in seconds

    event FundsDeposited(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 indexed destinationChainId,
        uint256 indexed depositId,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes32 indexed depositor,
        bytes32 recipient,
        bytes32 exclusiveRelayer,
        bytes message
    );

    event RequestedSpeedUpDeposit(
        uint256 updatedOutputAmount,
        uint256 indexed depositId,
        bytes32 indexed depositor,
        bytes32 updatedRecipient,
        bytes updatedMessage,
        bytes depositorSignature
    );

    function setUp() public {
        owner = makeAddr("owner");
        crossDomainAdmin = makeAddr("crossDomainAdmin");
        hubPool = makeAddr("hubPool");
        depositorPrivateKey = 0x12345;
        depositor = vm.addr(depositorPrivateKey);
        recipient = makeAddr("recipient");

        weth = new WETH9();

        // Deploy ERC20 token
        erc20 = new ExpandedERC20("USD Coin", "USDC", 18);
        erc20.addMember(1, address(this)); // Minter role

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

        // Seed depositor with tokens
        erc20.mint(depositor, AMOUNT_TO_SEED);
        vm.deal(depositor, AMOUNT_TO_SEED);
        vm.prank(depositor);
        weth.deposit{ value: AMOUNT_TO_SEED }();

        // Approve spokepool to spend tokens
        vm.startPrank(depositor);
        erc20.approve(address(spokePool), AMOUNT_TO_DEPOSIT * 10);
        weth.approve(address(spokePool), AMOUNT_TO_DEPOSIT * 10);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT V3 TESTS
    //////////////////////////////////////////////////////////////*/

    function testDeposit() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0), // exclusiveRelayer
            quoteTimestamp,
            fillDeadline,
            0, // exclusivityDeadline
            ""
        );

        assertEq(spokePool.numberOfDeposits(), 1);
    }

    function testDepositV3WithAddressOverload() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        vm.prank(depositor);
        spokePool.depositV3(
            depositor,
            recipient,
            address(erc20),
            makeAddr("outputToken"),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            address(0), // exclusiveRelayer
            quoteTimestamp,
            fillDeadline,
            0, // exclusivityDeadline
            ""
        );

        assertEq(spokePool.numberOfDeposits(), 1);
    }

    function testInvalidQuoteTimestampTooOld() public {
        // Set a higher current time so we can test quoteTimeBuffer properly
        uint32 quoteTimeBuffer = spokePool.depositQuoteTimeBuffer();
        spokePool.setCurrentTime(quoteTimeBuffer + 1000);
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = currentTime + 1000;

        // quoteTimestamp too far into past (beyond buffer) - should revert
        vm.prank(depositor);
        vm.expectRevert(V3SpokePoolInterface.InvalidQuoteTimestamp.selector);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            currentTime - quoteTimeBuffer - 1,
            fillDeadline,
            0,
            ""
        );
    }

    function testInvalidQuoteTimestampInFuture() public {
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = currentTime + 1000;

        // quoteTimestamp in the future - should revert
        vm.prank(depositor);
        vm.expectRevert(V3SpokePoolInterface.InvalidQuoteTimestamp.selector);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            currentTime + 500,
            fillDeadline,
            0,
            ""
        );
    }

    function testValidQuoteTimestampAtBuffer() public {
        // Set a higher current time so we can test quoteTimeBuffer properly
        uint32 quoteTimeBuffer = spokePool.depositQuoteTimeBuffer();
        spokePool.setCurrentTime(quoteTimeBuffer + 1000);
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = currentTime + 1000;

        // quoteTimestamp right at buffer - should succeed
        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            currentTime - quoteTimeBuffer,
            fillDeadline,
            0,
            ""
        );
    }

    function testInvalidFillDeadline() public {
        uint32 fillDeadlineBuffer = spokePool.fillDeadlineBuffer();
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 quoteTimestamp = currentTime;

        // fillDeadline too far into future (beyond buffer) - should revert
        vm.prank(depositor);
        vm.expectRevert(V3SpokePoolInterface.InvalidFillDeadline.selector);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            currentTime + fillDeadlineBuffer + 1,
            0,
            ""
        );

        // fillDeadline in past - should succeed
        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            currentTime - 1,
            0,
            ""
        );

        // fillDeadline right at buffer - should succeed
        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            currentTime + fillDeadlineBuffer,
            0,
            ""
        );
    }

    function testInvalidExclusivityParamsNonZeroDeadlineZeroRelayer() public {
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = currentTime + 1000;

        // If exclusive deadline is not zero, then exclusive relayer must be set
        vm.prank(depositor);
        vm.expectRevert(V3SpokePoolInterface.InvalidExclusiveRelayer.selector);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0), // zero exclusive relayer
            currentTime,
            fillDeadline,
            1, // non-zero exclusivity deadline
            ""
        );
    }

    function testInvalidExclusivityParamsMaxOffset() public {
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = currentTime + 1000;

        vm.prank(depositor);
        vm.expectRevert(V3SpokePoolInterface.InvalidExclusiveRelayer.selector);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            currentTime,
            fillDeadline,
            MAX_EXCLUSIVITY_OFFSET_SECONDS,
            ""
        );
    }

    function testInvalidExclusivityParamsTimestampWithZeroRelayer() public {
        // Set a higher current time so that timestamp-based tests work correctly
        spokePool.setCurrentTime(MAX_EXCLUSIVITY_OFFSET_SECONDS + 1000);
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = currentTime + 1000;

        // When exclusivityParameter > MAX_EXCLUSIVITY_OFFSET_SECONDS, it's treated as a timestamp
        // If it's non-zero and relayer is zero, should revert
        vm.prank(depositor);
        vm.expectRevert(V3SpokePoolInterface.InvalidExclusiveRelayer.selector);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            currentTime,
            fillDeadline,
            MAX_EXCLUSIVITY_OFFSET_SECONDS + 1, // treated as timestamp
            ""
        );

        // Past timestamp (but still > MAX_EXCLUSIVITY_OFFSET_SECONDS) should also revert
        vm.prank(depositor);
        vm.expectRevert(V3SpokePoolInterface.InvalidExclusiveRelayer.selector);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            currentTime,
            fillDeadline,
            currentTime - 1, // past timestamp but > MAX_EXCLUSIVITY_OFFSET_SECONDS
            ""
        );

        // Future timestamp should also revert
        vm.prank(depositor);
        vm.expectRevert(V3SpokePoolInterface.InvalidExclusiveRelayer.selector);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            currentTime,
            fillDeadline,
            currentTime + 1, // future timestamp > MAX_EXCLUSIVITY_OFFSET_SECONDS
            ""
        );
    }

    function testValidExclusivityParamsZeroDeadlineZeroRelayer() public {
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = currentTime + 1000;

        // exclusivityDeadline = 0 with zero relayer - should succeed
        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            currentTime,
            fillDeadline,
            0,
            ""
        );
    }

    function testExclusivityParamUsedAsOffset() public {
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadlineOffset = 1000;
        uint32 exclusivityDeadlineOffset = MAX_EXCLUSIVITY_OFFSET_SECONDS;
        address outputToken = makeAddr("outputToken");

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            0, // deposit ID
            currentTime,
            currentTime + fillDeadlineOffset,
            currentTime + exclusivityDeadlineOffset, // exclusivityDeadline = current time + offset
            depositor.toBytes32(),
            recipient.toBytes32(),
            depositor.toBytes32(), // exclusive relayer
            ""
        );

        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            depositor.toBytes32(), // exclusive relayer
            currentTime,
            currentTime + fillDeadlineOffset,
            exclusivityDeadlineOffset,
            ""
        );
    }

    function testExclusivityParamUsedAsTimestamp() public {
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadlineOffset = 1000;
        uint32 exclusivityDeadlineTimestamp = MAX_EXCLUSIVITY_OFFSET_SECONDS + 1;
        address outputToken = makeAddr("outputToken");

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            0,
            currentTime,
            currentTime + fillDeadlineOffset,
            exclusivityDeadlineTimestamp, // exclusivityDeadline = passed in timestamp
            depositor.toBytes32(),
            recipient.toBytes32(),
            depositor.toBytes32(),
            ""
        );

        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            depositor.toBytes32(),
            currentTime,
            currentTime + fillDeadlineOffset,
            exclusivityDeadlineTimestamp,
            ""
        );
    }

    function testExclusivityParamSetToZero() public {
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadlineOffset = 1000;
        address outputToken = makeAddr("outputToken");

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            0,
            currentTime,
            currentTime + fillDeadlineOffset,
            0, // exclusivityDeadline = 0
            depositor.toBytes32(),
            recipient.toBytes32(),
            depositor.toBytes32(),
            ""
        );

        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            depositor.toBytes32(),
            currentTime,
            currentTime + fillDeadlineOffset,
            0, // zero exclusivity
            ""
        );
    }

    function testWethDepositMsgValueMustMatchInputAmount() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        // msg.value > 0 but doesn't match inputAmount - should revert
        vm.deal(depositor, AMOUNT_TO_DEPOSIT);
        vm.startPrank(depositor);
        vm.expectRevert(V3SpokePoolInterface.MsgValueDoesNotMatchInputAmount.selector);
        spokePool.deposit{ value: 1 }(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(weth).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );
        vm.stopPrank();

        // msg.value matches inputAmount - ETH should transfer from depositor to WETH contract
        uint256 wethBalBefore = weth.balanceOf(address(spokePool));

        // Give depositor some ETH for this test
        vm.deal(depositor, AMOUNT_TO_DEPOSIT);

        vm.prank(depositor);
        spokePool.deposit{ value: AMOUNT_TO_DEPOSIT }(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(weth).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );

        assertEq(weth.balanceOf(address(spokePool)), wethBalBefore + AMOUNT_TO_DEPOSIT);
    }

    function testNonWethDepositMsgValueMustBeZero() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        vm.deal(depositor, 1 ether);
        vm.startPrank(depositor);
        vm.expectRevert(V3SpokePoolInterface.MsgValueDoesNotMatchInputAmount.selector);
        spokePool.deposit{ value: 1 }(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );
        vm.stopPrank();
    }

    function testWethDepositZeroMsgValuePullsErc20() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        uint256 depositorWethBefore = weth.balanceOf(depositor);
        uint256 poolWethBefore = weth.balanceOf(address(spokePool));

        vm.prank(depositor);
        spokePool.deposit{ value: 0 }(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(weth).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );

        assertEq(weth.balanceOf(depositor), depositorWethBefore - AMOUNT_TO_DEPOSIT);
        assertEq(weth.balanceOf(address(spokePool)), poolWethBefore + AMOUNT_TO_DEPOSIT);
    }

    function testPullsInputTokenFromCaller() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        uint256 depositorBalBefore = erc20.balanceOf(depositor);
        uint256 poolBalBefore = erc20.balanceOf(address(spokePool));

        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );

        assertEq(erc20.balanceOf(depositor), depositorBalBefore - AMOUNT_TO_DEPOSIT);
        assertEq(erc20.balanceOf(address(spokePool)), poolBalBefore + AMOUNT_TO_DEPOSIT);
    }

    function testDepositNowUsesCurrentTimeAsQuoteTime() public {
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadlineOffset = 1000;
        address outputToken = makeAddr("outputToken");

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            0,
            currentTime, // quoteTimestamp = current time
            currentTime + fillDeadlineOffset,
            0,
            depositor.toBytes32(),
            recipient.toBytes32(),
            bytes32(0),
            ""
        );

        vm.prank(depositor);
        spokePool.depositNow(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            fillDeadlineOffset,
            0,
            ""
        );
    }

    function testDepositV3NowWithAddressOverload() public {
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        uint32 fillDeadlineOffset = 1000;
        address outputToken = makeAddr("outputToken");

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            0,
            currentTime,
            currentTime + fillDeadlineOffset,
            0,
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(0).toBytes32(),
            ""
        );

        vm.prank(depositor);
        spokePool.depositV3Now(
            depositor,
            recipient,
            address(erc20),
            outputToken,
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            address(0),
            fillDeadlineOffset,
            0,
            ""
        );
    }

    function testEmitsFundsDepositedEventWithCorrectDepositId() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;
        address outputToken = makeAddr("outputToken");

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            0, // first deposit ID is 0
            quoteTimestamp,
            fillDeadline,
            0,
            depositor.toBytes32(),
            recipient.toBytes32(),
            bytes32(0),
            ""
        );

        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );
    }

    function testDepositIdStateVariableIncremented() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        assertEq(spokePool.numberOfDeposits(), 0);

        vm.prank(depositor);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );

        assertEq(spokePool.numberOfDeposits(), 1);
    }

    function testTokensAlwaysPulledFromCallerEvenIfDifferentFromDepositor() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;
        address newDepositor = makeAddr("newDepositor");
        address outputToken = makeAddr("outputToken");

        uint256 balanceBefore = erc20.balanceOf(depositor);

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            0,
            quoteTimestamp,
            fillDeadline,
            0,
            newDepositor.toBytes32(), // new depositor
            recipient.toBytes32(),
            bytes32(0),
            ""
        );

        vm.prank(depositor);
        spokePool.deposit(
            newDepositor.toBytes32(), // different depositor
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );

        // Tokens pulled from caller (depositor), not from newDepositor
        assertEq(erc20.balanceOf(depositor), balanceBefore - AMOUNT_TO_DEPOSIT);
    }

    function testDepositsArePaused() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        vm.prank(owner);
        spokePool.pauseDeposits(true);

        vm.prank(depositor);
        vm.expectRevert(SpokePoolInterface.DepositsArePaused.selector);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );
    }

    function testReentrancyProtected() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        bytes memory functionCalldata = abi.encodeCall(
            spokePool.deposit,
            (
                depositor.toBytes32(),
                recipient.toBytes32(),
                address(erc20).toBytes32(),
                makeAddr("outputToken").toBytes32(),
                AMOUNT_TO_DEPOSIT,
                AMOUNT_TO_DEPOSIT - 19,
                DESTINATION_CHAIN_ID,
                bytes32(0),
                quoteTimestamp,
                fillDeadline,
                0,
                ""
            )
        );

        vm.prank(depositor);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        spokePool.callback(functionCalldata);
    }

    function testDepositorMustBeValidEvmAddress() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        // Invalid depositor address (non-EVM address with high bits set)
        bytes32 invalidDepositor = 0x044852b2a670ade5407e78fb2863c51de9fcb96542a07186fe3aeda6bb8a116d;

        vm.prank(depositor);
        vm.expectRevert(Bytes32ToAddress.InvalidBytes32.selector);
        spokePool.deposit(
            invalidDepositor,
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            makeAddr("outputToken").toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );
    }

    function testOutputTokenCannotBeZeroAddress() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;

        vm.prank(depositor);
        vm.expectRevert(V3SpokePoolInterface.InvalidOutputToken.selector);
        spokePool.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            bytes32(0), // zero output token
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );
    }

    function testUnsafeDepositId() public {
        uint32 quoteTimestamp = uint32(spokePool.getCurrentTime());
        uint32 fillDeadline = quoteTimestamp + 1000;
        uint256 forcedDepositId = 99;
        address outputToken = makeAddr("outputToken");

        // Expected deposit ID = keccak256(msg.sender, depositor, forcedDepositId)
        uint256 expectedDepositId = uint256(
            keccak256(abi.encodePacked(depositor, recipient.toBytes32(), forcedDepositId))
        );

        assertEq(spokePool.getUnsafeDepositId(depositor, recipient.toBytes32(), forcedDepositId), expectedDepositId);

        // Note: we deliberately set the depositor != msg.sender to test that hashing includes both
        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            expectedDepositId,
            quoteTimestamp,
            fillDeadline,
            0,
            recipient.toBytes32(), // depositor is recipient
            recipient.toBytes32(),
            bytes32(0),
            ""
        );

        vm.prank(depositor);
        spokePool.unsafeDeposit(
            recipient.toBytes32(), // different depositor
            recipient.toBytes32(),
            address(erc20).toBytes32(),
            outputToken.toBytes32(),
            AMOUNT_TO_DEPOSIT,
            AMOUNT_TO_DEPOSIT - 19,
            DESTINATION_CHAIN_ID,
            bytes32(0),
            forcedDepositId,
            quoteTimestamp,
            fillDeadline,
            0,
            ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                        SPEED UP V3 DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function testVerifyUpdateV3DepositMessage() public {
        uint256 depositId = 100;
        uint256 updatedOutputAmount = AMOUNT_TO_DEPOSIT + 1;
        bytes memory updatedMessage = hex"1234";

        bytes memory signature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            depositId,
            ORIGIN_CHAIN_ID,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage
        );

        // Valid signature should not revert
        spokePool.verifyUpdateV3DepositMessageBytes32(
            depositor.toBytes32(),
            depositId,
            ORIGIN_CHAIN_ID,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage,
            signature
        );

        // Wrong depositor should revert
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.verifyUpdateV3DepositMessageBytes32(
            recipient.toBytes32(), // wrong depositor
            depositId,
            ORIGIN_CHAIN_ID,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage,
            signature
        );

        // Invalid signature (different params) should revert
        bytes memory invalidSignature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            depositId + 1, // different deposit ID
            ORIGIN_CHAIN_ID,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage
        );

        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.verifyUpdateV3DepositMessageBytes32(
            depositor.toBytes32(),
            depositId,
            ORIGIN_CHAIN_ID,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage,
            invalidSignature
        );
    }

    function testSpeedUpDepositPassesSpokePoolChainId() public {
        uint256 depositId = 100;
        uint256 updatedOutputAmount = AMOUNT_TO_DEPOSIT + 1;
        bytes memory updatedMessage = hex"1234";
        uint256 spokePoolChainId = spokePool.chainId();

        bytes memory expectedSignature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            depositId,
            spokePoolChainId,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage
        );

        vm.expectEmit(true, true, true, true);
        emit RequestedSpeedUpDeposit(
            updatedOutputAmount,
            depositId,
            depositor.toBytes32(),
            recipient.toBytes32(),
            updatedMessage,
            expectedSignature
        );

        vm.prank(depositor);
        spokePool.speedUpDeposit(
            depositor.toBytes32(),
            depositId,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage,
            expectedSignature
        );

        // Can't use a signature for a different chain ID
        uint256 otherChainId = spokePoolChainId + 1;
        bytes memory invalidSignatureForChain = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            depositId,
            otherChainId,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage
        );

        // Verify passes with correct chain ID
        spokePool.verifyUpdateV3DepositMessageBytes32(
            depositor.toBytes32(),
            depositId,
            otherChainId,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage,
            invalidSignatureForChain
        );

        // But speedUpDeposit uses spoke pool's chain ID, so should fail
        vm.prank(depositor);
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.speedUpDeposit(
            depositor.toBytes32(),
            depositId,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage,
            invalidSignatureForChain
        );
    }

    function testSpeedUpV3DepositWithAddressOverload() public {
        uint256 depositId = 100;
        uint256 updatedOutputAmount = AMOUNT_TO_DEPOSIT + 1;
        bytes memory updatedMessage = hex"1234";
        uint256 spokePoolChainId = spokePool.chainId();

        bytes memory signature = _getUpdatedV3DepositSignature(
            depositorPrivateKey,
            depositId,
            spokePoolChainId,
            updatedOutputAmount,
            recipient.toBytes32(),
            updatedMessage
        );

        // Verify with address overload
        spokePool.verifyUpdateV3DepositMessage(
            depositor,
            depositId,
            spokePoolChainId,
            updatedOutputAmount,
            recipient,
            updatedMessage,
            signature
        );

        vm.expectEmit(true, true, true, true);
        emit RequestedSpeedUpDeposit(
            updatedOutputAmount,
            depositId,
            depositor.toBytes32(),
            recipient.toBytes32(),
            updatedMessage,
            signature
        );

        vm.prank(depositor);
        spokePool.speedUpV3Deposit(depositor, depositId, updatedOutputAmount, recipient, updatedMessage, signature);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
}
