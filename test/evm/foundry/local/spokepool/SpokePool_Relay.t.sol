// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { MintableERC20 } from "../../../../../contracts/test/MockERC20.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { V3SpokePoolInterface } from "../../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { SpokePoolInterface } from "../../../../../contracts/interfaces/SpokePoolInterface.sol";
import { SpokePoolUtils } from "../../utils/SpokePoolUtils.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../../../../../contracts/libraries/AddressConverters.sol";

/**
 * @title SpokePool_RelayTest
 * @notice Tests for SpokePool relay/fill functionality.
 * @dev Migrated from test/evm/hardhat/SpokePool.Relay.ts
 */
contract SpokePool_RelayTest is Test {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    MockSpokePool public spokePool;
    MintableERC20 public erc20;
    MintableERC20 public destErc20;
    WETH9 public weth;

    address public depositor;
    uint256 public depositorKey;
    address public recipient;
    address public relayer;

    uint256 public destinationChainId;

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
        (depositor, depositorKey) = makeAddrAndKey("depositor");
        recipient = makeAddr("recipient");
        relayer = makeAddr("relayer");

        // Deploy WETH
        weth = new WETH9();

        // Deploy test tokens
        erc20 = new MintableERC20("Input Token", "INPUT", 18);
        destErc20 = new MintableERC20("Output Token", "OUTPUT", 18);

        // Deploy SpokePool
        vm.startPrank(depositor);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(weth))),
            abi.encodeCall(MockSpokePool.initialize, (0, depositor, depositor))
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(SpokePoolUtils.DESTINATION_CHAIN_ID);
        vm.stopPrank();

        destinationChainId = spokePool.chainId();

        // Mint tokens to relayer and approve spokePool
        destErc20.mint(relayer, SpokePoolUtils.AMOUNT_TO_DEPOSIT * 10);
        vm.prank(relayer);
        destErc20.approve(address(spokePool), type(uint256).max);

        // Mint WETH to relayer for WETH tests
        vm.deal(relayer, SpokePoolUtils.AMOUNT_TO_DEPOSIT * 10);
        vm.prank(relayer);
        weth.deposit{ value: SpokePoolUtils.AMOUNT_TO_DEPOSIT * 5 }();
        vm.prank(relayer);
        weth.approve(address(spokePool), type(uint256).max);
    }

    // ============ Helper Functions ============

    function _createRelayData() internal view returns (V3SpokePoolInterface.V3RelayData memory relayData) {
        uint32 currentTime = uint32(spokePool.getCurrentTime());
        relayData = V3SpokePoolInterface.V3RelayData({
            depositor: depositor.toBytes32(),
            recipient: recipient.toBytes32(),
            exclusiveRelayer: relayer.toBytes32(),
            inputToken: address(erc20).toBytes32(),
            outputToken: address(destErc20).toBytes32(),
            inputAmount: SpokePoolUtils.AMOUNT_TO_DEPOSIT,
            outputAmount: SpokePoolUtils.AMOUNT_TO_DEPOSIT,
            originChainId: SpokePoolUtils.ORIGIN_CHAIN_ID,
            depositId: 0,
            fillDeadline: currentTime + 1000,
            exclusivityDeadline: currentTime + 500,
            message: ""
        });
    }

    function _createRelayExecutionParams(
        V3SpokePoolInterface.V3RelayData memory relayData
    ) internal view returns (V3SpokePoolInterface.V3RelayExecutionParams memory) {
        return
            V3SpokePoolInterface.V3RelayExecutionParams({
                relay: relayData,
                relayHash: SpokePoolUtils.getV3RelayHash(relayData, destinationChainId),
                updatedOutputAmount: relayData.outputAmount,
                updatedRecipient: relayData.recipient,
                updatedMessage: relayData.message,
                repaymentChainId: SpokePoolUtils.REPAYMENT_CHAIN_ID
            });
    }

    // ============ Tests ============

    /**
     * @notice Test that default fill status is unfilled.
     */
    function testFillV3DefaultStatus() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        bytes32 relayHash = SpokePoolUtils.getV3RelayHash(relayData, destinationChainId);

        assertEq(spokePool.fillStatuses(relayHash), uint256(V3SpokePoolInterface.FillStatus.Unfilled));
    }

    /**
     * @notice Test that expired fill deadline reverts.
     */
    function testFillV3ExpiredDeadline() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.fillDeadline = 0; // Expired

        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _createRelayExecutionParams(relayData);

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.ExpiredFillDeadline.selector);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);
    }

    /**
     * @notice Test that double-fill is prevented.
     */
    function testFillV3DoubleFill() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _createRelayExecutionParams(relayData);

        // Set fill status to Filled (FillType.SlowFill = 2 maps to FillStatus.Filled)
        spokePool.setFillStatus(relayExecution.relayHash, V3SpokePoolInterface.FillType.SlowFill);

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);
    }

    /**
     * @notice Test correct fill type when replacing slow fill request.
     */
    function testFillV3ReplacedSlowFillType() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _createRelayExecutionParams(relayData);

        // Set fill status to RequestedSlowFill (FillType.ReplacedSlowFill = 1 maps to FillStatus.RequestedSlowFill)
        spokePool.setFillStatus(relayExecution.relayHash, V3SpokePoolInterface.FillType.ReplacedSlowFill);

        // Fast fill should replace the slow fill request
        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);

        // Status should now be Filled
        assertEq(spokePool.fillStatuses(relayExecution.relayHash), uint256(V3SpokePoolInterface.FillStatus.Filled));
    }

    /**
     * @notice Test token transfer to recipient during fill.
     */
    function testFillV3TokenTransfer() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _createRelayExecutionParams(relayData);

        uint256 relayerBalanceBefore = destErc20.balanceOf(relayer);
        uint256 recipientBalanceBefore = destErc20.balanceOf(recipient);

        // Set time to after exclusivity deadline so anyone can fill
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);

        // Relayer should have sent tokens
        assertEq(destErc20.balanceOf(relayer), relayerBalanceBefore - relayData.outputAmount);
        // Recipient should have received tokens
        assertEq(destErc20.balanceOf(recipient), recipientBalanceBefore + relayData.outputAmount);
    }

    /**
     * @notice Test that fill uses updated output amount.
     */
    function testFillV3UpdatedOutputAmount() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _createRelayExecutionParams(relayData);

        // Use different updated output amount
        uint256 updatedOutputAmount = relayData.outputAmount - 10;
        relayExecution.updatedOutputAmount = updatedOutputAmount;

        uint256 recipientBalanceBefore = destErc20.balanceOf(recipient);

        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);

        // Recipient should receive updated amount
        assertEq(destErc20.balanceOf(recipient), recipientBalanceBefore + updatedOutputAmount);
    }

    /**
     * @notice Test WETH unwrapping when output token is WETH.
     */
    function testFillV3WethUnwrap() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.outputToken = address(weth).toBytes32();

        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _createRelayExecutionParams(relayData);

        uint256 recipientEthBefore = recipient.balance;

        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), false);

        // Recipient should receive ETH (unwrapped WETH)
        assertEq(recipient.balance, recipientEthBefore + relayData.outputAmount);
    }

    /**
     * @notice Test slow fill uses contract balance.
     */
    function testFillV3SlowFillBalance() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3RelayExecutionParams memory relayExecution = _createRelayExecutionParams(relayData);

        // Fund the spokePool for slow fill
        destErc20.mint(address(spokePool), relayData.outputAmount);

        uint256 spokePoolBalanceBefore = destErc20.balanceOf(address(spokePool));
        uint256 recipientBalanceBefore = destErc20.balanceOf(recipient);

        vm.prank(relayer);
        spokePool.fillRelayV3Internal(relayExecution, relayer.toBytes32(), true); // isSlowFill = true

        // SpokePool should have sent tokens
        assertEq(destErc20.balanceOf(address(spokePool)), spokePoolBalanceBefore - relayData.outputAmount);
        // Recipient should have received tokens
        assertEq(destErc20.balanceOf(recipient), recipientBalanceBefore + relayData.outputAmount);
    }

    /**
     * @notice Test fill is paused when fills are paused.
     */
    function testFillV3Paused() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        vm.prank(depositor);
        spokePool.pauseFills(true);

        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.FillsArePaused.selector);
        spokePool.fillRelay(relayData, SpokePoolUtils.REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }

    /**
     * @notice Test fill reentrancy protection.
     */
    function testFillV3Reentrancy() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        bytes memory fillCalldata = abi.encodeCall(
            spokePool.fillRelay,
            (relayData, SpokePoolUtils.REPAYMENT_CHAIN_ID, relayer.toBytes32())
        );

        vm.prank(depositor);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        spokePool.callback(fillCalldata);
    }

    /**
     * @notice Test exclusive relayer enforcement.
     */
    function testFillV3ExclusiveRelayer() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        // Exclusive relayer is set to 'relayer'

        address nonExclusiveRelayer = makeAddr("nonExclusiveRelayer");
        destErc20.mint(nonExclusiveRelayer, relayData.outputAmount);
        vm.prank(nonExclusiveRelayer);
        destErc20.approve(address(spokePool), type(uint256).max);

        // Before exclusivity deadline, only exclusive relayer can fill
        spokePool.setCurrentTime(relayData.exclusivityDeadline - 1);

        vm.prank(nonExclusiveRelayer);
        vm.expectRevert(V3SpokePoolInterface.NotExclusiveRelayer.selector);
        spokePool.fillRelay(relayData, SpokePoolUtils.REPAYMENT_CHAIN_ID, nonExclusiveRelayer.toBytes32());

        // Exclusive relayer can fill during exclusivity period
        vm.prank(relayer);
        spokePool.fillRelay(relayData, SpokePoolUtils.REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }

    /**
     * @notice Test fill with updated deposit signature.
     */
    function testFillRelayWithUpdatedDeposit() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        uint256 updatedOutputAmount = relayData.outputAmount - 10;
        bytes32 updatedRecipient = relayData.recipient;
        bytes memory updatedMessage = "";

        // Sign the update on the origin chain
        bytes memory signature = SpokePoolUtils.signUpdateV3Deposit(
            vm,
            depositorKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage
        );

        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        uint256 recipientBalanceBefore = destErc20.balanceOf(recipient);

        vm.prank(relayer);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            SpokePoolUtils.REPAYMENT_CHAIN_ID,
            relayer.toBytes32(), // repaymentAddress
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage,
            signature
        );

        // Should receive updated output amount
        assertEq(destErc20.balanceOf(recipient), recipientBalanceBefore + updatedOutputAmount);
    }

    /**
     * @notice Test fill with invalid updated deposit signature reverts.
     */
    function testFillRelayWithUpdatedDepositInvalidSignature() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        uint256 updatedOutputAmount = relayData.outputAmount - 10;
        bytes32 updatedRecipient = relayData.recipient;
        bytes memory updatedMessage = "";

        // Sign with wrong key
        (, uint256 wrongKey) = makeAddrAndKey("wrongSigner");
        bytes memory badSignature = SpokePoolUtils.signUpdateV3Deposit(
            vm,
            wrongKey,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage
        );

        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.InvalidDepositorSignature.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            SpokePoolUtils.REPAYMENT_CHAIN_ID,
            relayer.toBytes32(), // repaymentAddress
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage,
            badSignature
        );
    }

    /**
     * @notice Test fillRelay convenience function.
     */
    function testFillRelay() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        uint256 recipientBalanceBefore = destErc20.balanceOf(recipient);

        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        vm.prank(relayer);
        spokePool.fillRelay(relayData, SpokePoolUtils.REPAYMENT_CHAIN_ID, relayer.toBytes32());

        assertEq(destErc20.balanceOf(recipient), recipientBalanceBefore + relayData.outputAmount);
    }

    /**
     * @notice Test fill after exclusivity deadline by non-exclusive relayer.
     */
    function testFillV3AfterExclusivity() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        address nonExclusiveRelayer = makeAddr("nonExclusiveRelayer");
        destErc20.mint(nonExclusiveRelayer, relayData.outputAmount);
        vm.prank(nonExclusiveRelayer);
        destErc20.approve(address(spokePool), type(uint256).max);

        // After exclusivity deadline, anyone can fill
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        uint256 recipientBalanceBefore = destErc20.balanceOf(recipient);

        vm.prank(nonExclusiveRelayer);
        spokePool.fillRelay(relayData, SpokePoolUtils.REPAYMENT_CHAIN_ID, nonExclusiveRelayer.toBytes32());

        assertEq(destErc20.balanceOf(recipient), recipientBalanceBefore + relayData.outputAmount);
    }
}
