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
import { AddressToBytes32 } from "../../../../../contracts/libraries/AddressConverters.sol";

/**
 * @title SpokePool_SlowRelayTest
 * @notice Tests for SpokePool slow relay functionality.
 * @dev Migrated from test/evm/hardhat/SpokePool.SlowRelay.ts
 */
contract SpokePool_SlowRelayTest is Test {
    using AddressToBytes32 for address;

    MockSpokePool public spokePool;
    MintableERC20 public erc20;
    MintableERC20 public destErc20;
    WETH9 public weth;

    address public depositor;
    address public recipient;
    address public relayer;

    uint256 public destinationChainId;

    // Slow fill should only deduct LP fee, not relayer fee
    uint256 public fullRelayAmountPostFees;

    // Mock merkle root
    bytes32 public mockTreeRoot;

    event RequestedSlowFill(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 indexed originChainId,
        uint256 indexed depositId,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes32 exclusiveRelayer,
        bytes32 depositor,
        bytes32 recipient,
        bytes32 messageHash
    );

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

    event PreLeafExecuteHook(bytes32 token);

    function setUp() public {
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        relayer = makeAddr("relayer");

        mockTreeRoot = SpokePoolUtils.createRandomBytes32(1);

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

        // Calculate full relay amount post fees (only LP fee, no relayer fee for slow fills)
        fullRelayAmountPostFees =
            (SpokePoolUtils.AMOUNT_TO_RELAY * (1e18 - uint256(int256(SpokePoolUtils.REALIZED_LP_FEE_PCT)))) /
            1e18;

        // Seed the spoke pool with tokens for slow fills
        destErc20.mint(address(spokePool), fullRelayAmountPostFees * 10);

        // Seed relayer with tokens for fast fills
        destErc20.mint(relayer, SpokePoolUtils.AMOUNT_TO_DEPOSIT * 10);
        vm.prank(relayer);
        destErc20.approve(address(spokePool), type(uint256).max);
    }

    // ============ Helper Functions ============

    function _createRelayData(uint32 fillDeadline) internal view returns (V3SpokePoolInterface.V3RelayData memory) {
        return
            V3SpokePoolInterface.V3RelayData({
                depositor: depositor.toBytes32(),
                recipient: recipient.toBytes32(),
                exclusiveRelayer: relayer.toBytes32(),
                inputToken: address(erc20).toBytes32(),
                outputToken: address(destErc20).toBytes32(),
                inputAmount: SpokePoolUtils.AMOUNT_TO_DEPOSIT,
                outputAmount: fullRelayAmountPostFees,
                originChainId: SpokePoolUtils.ORIGIN_CHAIN_ID,
                depositId: 0,
                fillDeadline: fillDeadline,
                exclusivityDeadline: fillDeadline - 500,
                message: ""
            });
    }

    function _createSlowFillLeaf(
        V3SpokePoolInterface.V3RelayData memory relayData,
        uint256 updatedOutputAmount
    ) internal view returns (V3SpokePoolInterface.V3SlowFill memory) {
        return
            V3SpokePoolInterface.V3SlowFill({
                relayData: relayData,
                chainId: destinationChainId,
                updatedOutputAmount: updatedOutputAmount
            });
    }

    function _hashSlowFillLeaf(V3SpokePoolInterface.V3SlowFill memory slowFill) internal pure returns (bytes32) {
        return keccak256(abi.encode(slowFill));
    }

    function _buildSingleSlowFillTree(
        V3SpokePoolInterface.V3SlowFill memory slowFill
    ) internal pure returns (bytes32 root, bytes32[] memory proof) {
        root = _hashSlowFillLeaf(slowFill);
        proof = new bytes32[](0);
    }

    function _buildTwoSlowFillTree(
        V3SpokePoolInterface.V3SlowFill memory slowFill0,
        V3SpokePoolInterface.V3SlowFill memory slowFill1
    ) internal pure returns (bytes32 root, bytes32[] memory proof0, bytes32[] memory proof1) {
        bytes32 hash0 = _hashSlowFillLeaf(slowFill0);
        bytes32 hash1 = _hashSlowFillLeaf(slowFill1);

        // Standard merkle tree: parent = hash(min(left, right) || max(left, right))
        if (uint256(hash0) < uint256(hash1)) {
            root = keccak256(abi.encodePacked(hash0, hash1));
        } else {
            root = keccak256(abi.encodePacked(hash1, hash0));
        }

        proof0 = new bytes32[](1);
        proof0[0] = hash1;

        proof1 = new bytes32[](1);
        proof1[0] = hash0;
    }

    // ============ requestSlowFill Tests ============

    function testRequestSlowFillExpiredDeadline() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        // Set time to after exclusivity deadline
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        // Set fill deadline to be expired
        relayData.fillDeadline = uint32(spokePool.getCurrentTime()) - 1;

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.ExpiredFillDeadline.selector);
        spokePool.requestSlowFill(relayData);
    }

    function testRequestSlowFillNoExclusivity() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        // Set exclusivity deadline to 0 (no exclusivity)
        relayData.exclusivityDeadline = 0;

        // Even if current time is before fill deadline, no exclusivity means slow fill can be requested
        spokePool.setCurrentTime(currentTime);

        vm.prank(relayer);
        spokePool.requestSlowFill(relayData);
    }

    function testRequestSlowFillDuringExclusivity() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        // Set time to exactly at exclusivity deadline (still within exclusivity window)
        spokePool.setCurrentTime(relayData.exclusivityDeadline);

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.NoSlowFillsInExclusivityWindow.selector);
        spokePool.requestSlowFill(relayData);
    }

    function testRequestSlowFillBeforeFastFill() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        // Set time to after exclusivity deadline
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        bytes32 relayHash = SpokePoolUtils.getV3RelayHash(relayData, destinationChainId);

        // Status should be Unfilled
        assertEq(spokePool.fillStatuses(relayHash), uint256(V3SpokePoolInterface.FillStatus.Unfilled));

        // Request slow fill
        vm.prank(relayer);
        spokePool.requestSlowFill(relayData);

        // Status should now be RequestedSlowFill
        assertEq(spokePool.fillStatuses(relayHash), uint256(V3SpokePoolInterface.FillStatus.RequestedSlowFill));

        // Can't request slow fill again
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.InvalidSlowFillRequest.selector);
        spokePool.requestSlowFill(relayData);

        // But can still fast fill after requesting slow fill
        vm.prank(relayer);
        spokePool.fillRelay(relayData, SpokePoolUtils.REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }

    function testRequestSlowFillAlreadyFilled() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        // Set time to after exclusivity deadline
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        bytes32 relayHash = SpokePoolUtils.getV3RelayHash(relayData, destinationChainId);

        // Set fill status to Filled (FillType.SlowFill = 2 which maps to FillStatus.Filled = 2)
        spokePool.setFillStatus(relayHash, V3SpokePoolInterface.FillType.SlowFill);
        assertEq(spokePool.fillStatuses(relayHash), uint256(V3SpokePoolInterface.FillStatus.Filled));

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.InvalidSlowFillRequest.selector);
        spokePool.requestSlowFill(relayData);
    }

    function testRequestSlowFillPaused() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        // Set time to after exclusivity deadline
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        // Pause fills
        vm.prank(depositor);
        spokePool.pauseFills(true);

        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.FillsArePaused.selector);
        spokePool.requestSlowFill(relayData);
    }

    function testRequestSlowFillReentrancy() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        // Set time to after exclusivity deadline
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        bytes memory callData = abi.encodeCall(spokePool.requestSlowFill, (relayData));

        vm.prank(depositor);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        spokePool.callback(callData);
    }

    // ============ executeSlowRelayLeaf Tests ============

    function testExecuteSlowRelayLeaf() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        // Create slow fill leaf with different updated output amount
        uint256 updatedOutputAmount = relayData.outputAmount + 1;
        V3SpokePoolInterface.V3SlowFill memory slowFillLeaf = _createSlowFillLeaf(relayData, updatedOutputAmount);

        (bytes32 root, bytes32[] memory proof) = _buildSingleSlowFillTree(slowFillLeaf);

        vm.prank(depositor);
        spokePool.relayRootBundle(mockTreeRoot, root);

        uint256 recipientBalanceBefore = destErc20.balanceOf(recipient);
        uint256 spokePoolBalanceBefore = destErc20.balanceOf(address(spokePool));

        vm.prank(recipient);
        spokePool.executeSlowRelayLeaf(slowFillLeaf, 0, proof);

        // Recipient should receive the updatedOutputAmount
        assertEq(destErc20.balanceOf(recipient), recipientBalanceBefore + updatedOutputAmount);
        assertEq(destErc20.balanceOf(address(spokePool)), spokePoolBalanceBefore - updatedOutputAmount);
    }

    function testExecuteSlowRelayLeafDoubleExecution() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        V3SpokePoolInterface.V3SlowFill memory slowFillLeaf = _createSlowFillLeaf(
            relayData,
            relayData.outputAmount + 1
        );

        (bytes32 root, bytes32[] memory proof) = _buildSingleSlowFillTree(slowFillLeaf);

        vm.prank(depositor);
        spokePool.relayRootBundle(mockTreeRoot, root);

        // First execution should succeed
        vm.prank(relayer);
        spokePool.executeSlowRelayLeaf(slowFillLeaf, 0, proof);

        // Second execution should fail
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.executeSlowRelayLeaf(slowFillLeaf, 0, proof);

        // Fast fill after slow fill should also fail
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.fillRelay(slowFillLeaf.relayData, SpokePoolUtils.REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }

    function testExecuteSlowRelayLeafAfterFastFill() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        V3SpokePoolInterface.V3SlowFill memory slowFillLeaf = _createSlowFillLeaf(
            relayData,
            relayData.outputAmount + 1
        );

        (bytes32 root, bytes32[] memory proof) = _buildSingleSlowFillTree(slowFillLeaf);

        vm.prank(depositor);
        spokePool.relayRootBundle(mockTreeRoot, root);

        // Fast fill first
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);
        vm.prank(relayer);
        spokePool.fillRelay(slowFillLeaf.relayData, SpokePoolUtils.REPAYMENT_CHAIN_ID, relayer.toBytes32());

        // Slow fill after fast fill should fail
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.executeSlowRelayLeaf(slowFillLeaf, 0, proof);
    }

    function testExecuteSlowRelayLeafReentrancy() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        V3SpokePoolInterface.V3SlowFill memory slowFillLeaf = _createSlowFillLeaf(
            relayData,
            relayData.outputAmount + 1
        );

        (bytes32 root, bytes32[] memory proof) = _buildSingleSlowFillTree(slowFillLeaf);

        bytes memory callData = abi.encodeCall(spokePool.executeSlowRelayLeaf, (slowFillLeaf, 0, proof));

        vm.prank(depositor);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        spokePool.callback(callData);
    }

    function testExecuteSlowRelayLeafWhenPaused() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        V3SpokePoolInterface.V3SlowFill memory slowFillLeaf = _createSlowFillLeaf(
            relayData,
            relayData.outputAmount + 1
        );

        (bytes32 root, bytes32[] memory proof) = _buildSingleSlowFillTree(slowFillLeaf);

        vm.prank(depositor);
        spokePool.relayRootBundle(mockTreeRoot, root);

        // Pause fills
        vm.prank(depositor);
        spokePool.pauseFills(true);

        // Slow fill execution should still succeed even when paused
        vm.prank(relayer);
        spokePool.executeSlowRelayLeaf(slowFillLeaf, 0, proof);
    }

    function testExecuteSlowRelayLeafEmitsPreExecuteHook() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        V3SpokePoolInterface.V3SlowFill memory slowFillLeaf = _createSlowFillLeaf(
            relayData,
            relayData.outputAmount + 1
        );

        (bytes32 root, bytes32[] memory proof) = _buildSingleSlowFillTree(slowFillLeaf);

        vm.prank(depositor);
        spokePool.relayRootBundle(mockTreeRoot, root);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit PreLeafExecuteHook(relayData.outputToken);
        spokePool.executeSlowRelayLeaf(slowFillLeaf, 0, proof);
    }

    function testExecuteSlowRelayLeafInvalidChain() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        // Create slow fill leaf with wrong chain ID
        V3SpokePoolInterface.V3SlowFill memory slowFillLeaf = V3SpokePoolInterface.V3SlowFill({
            relayData: relayData,
            chainId: destinationChainId + 1, // Wrong chain ID
            updatedOutputAmount: relayData.outputAmount + 1
        });

        (bytes32 root, bytes32[] memory proof) = _buildSingleSlowFillTree(slowFillLeaf);

        vm.prank(depositor);
        spokePool.relayRootBundle(mockTreeRoot, root);

        // Should revert because chain ID doesn't match
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.InvalidMerkleProof.selector);
        spokePool.executeSlowRelayLeaf(slowFillLeaf, 0, proof);
    }

    function testExecuteSlowRelayLeafInvalidProof() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        V3SpokePoolInterface.V3SlowFill memory slowFillLeaf = _createSlowFillLeaf(
            relayData,
            relayData.outputAmount + 1
        );

        V3SpokePoolInterface.V3SlowFill memory differentLeaf = _createSlowFillLeaf(
            relayData,
            relayData.outputAmount + 2
        );

        (bytes32 root, bytes32[] memory proof0, ) = _buildTwoSlowFillTree(slowFillLeaf, differentLeaf);

        vm.prank(depositor);
        spokePool.relayRootBundle(mockTreeRoot, root);

        // Relay second root bundle with different root
        vm.prank(depositor);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Wrong root bundle ID
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.InvalidMerkleProof.selector);
        spokePool.executeSlowRelayLeaf(slowFillLeaf, 1, proof0);
    }

    function testExecuteSlowRelayLeafUsesUpdatedOutputAmount() public {
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData(currentTime + 1000);

        // Make updated output amount different from original
        uint256 updatedOutputAmount = relayData.outputAmount + 100;
        V3SpokePoolInterface.V3SlowFill memory slowFillLeaf = _createSlowFillLeaf(relayData, updatedOutputAmount);

        (bytes32 root, bytes32[] memory proof) = _buildSingleSlowFillTree(slowFillLeaf);

        vm.prank(depositor);
        spokePool.relayRootBundle(mockTreeRoot, root);

        uint256 recipientBalanceBefore = destErc20.balanceOf(recipient);

        vm.prank(relayer);
        spokePool.executeSlowRelayLeaf(slowFillLeaf, 0, proof);

        // Recipient should receive updatedOutputAmount, not the original outputAmount
        assertEq(destErc20.balanceOf(recipient), recipientBalanceBefore + updatedOutputAmount);
        assertTrue(updatedOutputAmount != relayData.outputAmount, "Test assumes updatedOutputAmount differs");
    }
}
