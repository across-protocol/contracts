// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

// Test utilities
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";

// Contract under test
import { Arbitrum_Adapter } from "../../../../contracts/chain-adapters/Arbitrum_Adapter.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";

// External dependencies
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { ArbitrumInboxLike, ArbitrumL1ERC20GatewayLike } from "../../../../contracts/interfaces/ArbitrumBridge.sol";

// Existing mocks
import { ArbitrumMockErc20GatewayRouter, Inbox } from "../../../../contracts/test/ArbitrumMocks.sol";
import { MockCCTPMessenger, MockCCTPMinter } from "../../../../contracts/test/MockCCTP.sol";
import { MockOFTMessenger } from "../../../../contracts/test/MockOFTMessenger.sol";
import { AdapterStore, MessengerTypes } from "../../../../contracts/AdapterStore.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @title Arbitrum_AdapterTest
 * @notice Foundry tests for Arbitrum_Adapter, ported from Hardhat tests.
 * @dev Tests relayMessage and relayTokens functionality via HubPool delegatecall.
 */
contract Arbitrum_AdapterTest is HubPoolTestBase {
    // ============ Contracts ============

    Arbitrum_Adapter adapter;

    // ============ Mocks ============

    Inbox inbox;
    ArbitrumMockErc20GatewayRouter gatewayRouter;
    MockCCTPMinter cctpMinter;
    MockCCTPMessenger cctpMessenger;
    MockOFTMessenger oftMessenger;
    AdapterStore adapterStore;

    // ============ Addresses ============

    address refundAddress;
    address mockSpoke;
    address gateway;

    // ============ Chain Constants (loaded from constants.json) ============

    uint256 ARBITRUM_CHAIN_ID;
    uint32 ARBITRUM_OFT_EID;
    uint32 ARBITRUM_CIRCLE_DOMAIN;

    // ============ Test Configuration ============

    // OFT fee cap is an immutable set via constructor - this is a test configuration choice
    uint256 constant TEST_OFT_FEE_CAP = 1 ether;

    // ============ Test Amounts ============

    uint256 constant TOKENS_TO_SEND = 100 ether;
    uint256 constant LP_FEES = 10 ether;

    // ============ Setup ============

    function setUp() public {
        // Load chain constants from constants.json
        ARBITRUM_CHAIN_ID = getChainId("ARBITRUM");
        ARBITRUM_OFT_EID = uint32(getOftEid(ARBITRUM_CHAIN_ID));
        ARBITRUM_CIRCLE_DOMAIN = getCircleDomainId(ARBITRUM_CHAIN_ID);

        // Create HubPool fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Create test addresses
        refundAddress = makeAddr("refundAddress");
        mockSpoke = makeAddr("mockSpoke");
        gateway = makeAddr("gateway");

        // Deploy Arbitrum-specific mocks
        inbox = new Inbox();
        gatewayRouter = new ArbitrumMockErc20GatewayRouter();
        gatewayRouter.setGateway(gateway);

        cctpMinter = new MockCCTPMinter();
        cctpMessenger = new MockCCTPMessenger(cctpMinter);

        adapterStore = new AdapterStore();
        oftMessenger = new MockOFTMessenger(address(fixture.usdt));

        // Deploy Arbitrum Adapter
        adapter = new Arbitrum_Adapter(
            ArbitrumInboxLike(address(inbox)),
            ArbitrumL1ERC20GatewayLike(address(gatewayRouter)),
            refundAddress,
            IERC20(address(fixture.usdc)),
            ITokenMessenger(address(cctpMessenger)),
            address(adapterStore),
            ARBITRUM_OFT_EID,
            TEST_OFT_FEE_CAP
        );

        // Configure HubPool with adapter
        fixture.hubPool.setCrossChainContracts(ARBITRUM_CHAIN_ID, address(adapter), mockSpoke);

        // Enable tokens and set pool rebalance routes
        enableToken(ARBITRUM_CHAIN_ID, address(fixture.dai), fixture.l2Dai);
        enableToken(ARBITRUM_CHAIN_ID, address(fixture.weth), fixture.l2Weth);
        enableToken(ARBITRUM_CHAIN_ID, address(fixture.usdc), fixture.l2Usdc);
        enableToken(ARBITRUM_CHAIN_ID, address(fixture.usdt), fixture.l2Usdt);
    }

    // ============ relayMessage Tests ============

    function test_relayMessage_CallsSpokePoolFunctions() public {
        address newAdmin = makeAddr("newAdmin");
        bytes memory functionData = abi.encodeWithSignature("setCrossDomainAdmin(address)", newAdmin);

        vm.expectEmit(true, true, true, true, address(inbox));
        emit Inbox.RetryableTicketCreated(
            mockSpoke,
            0, // l2CallValue
            adapter.L2_MAX_SUBMISSION_COST(),
            refundAddress,
            refundAddress,
            adapter.RELAY_MESSAGE_L2_GAS_LIMIT(),
            adapter.L2_GAS_PRICE(),
            functionData
        );

        uint256 inboxBalanceBefore = address(inbox).balance;
        fixture.hubPool.relaySpokePoolAdminFunction(ARBITRUM_CHAIN_ID, functionData);
        uint256 inboxBalanceAfter = address(inbox).balance;

        uint256 expectedEth = adapter.L2_MAX_SUBMISSION_COST() +
            adapter.L2_GAS_PRICE() *
            adapter.RELAY_MESSAGE_L2_GAS_LIMIT();
        assertEq(inboxBalanceAfter - inboxBalanceBefore, expectedEth, "Inbox balance change mismatch");
    }

    // ============ relayTokens Tests (ERC20 via Gateway) ============

    function test_relayTokens_ERC20_ViaArbitrumGateway() public {
        addLiquidity(fixture.dai, TOKENS_TO_SEND);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            ARBITRUM_CHAIN_ID,
            address(fixture.dai),
            TOKENS_TO_SEND,
            LP_FEES
        );

        proposeAndExecuteBundle(root, bytes32(0), bytes32(0));

        // Expected data sent to gateway
        bytes memory expectedData = abi.encode(adapter.L2_MAX_SUBMISSION_COST(), "");

        // Expect gateway call
        vm.expectEmit(true, true, true, true, address(gatewayRouter));
        emit ArbitrumMockErc20GatewayRouter.OutboundTransferCustomRefundCalled(
            address(fixture.dai),
            refundAddress,
            mockSpoke,
            TOKENS_TO_SEND,
            adapter.RELAY_TOKENS_L2_GAS_LIMIT(),
            adapter.L2_GAS_PRICE(),
            expectedData
        );

        // Expect relayRootBundle message to SpokePool
        vm.expectEmit(true, true, true, true, address(inbox));
        emit Inbox.RetryableTicketCreated(
            mockSpoke,
            0,
            adapter.L2_MAX_SUBMISSION_COST(),
            refundAddress,
            refundAddress,
            adapter.RELAY_MESSAGE_L2_GAS_LIMIT(),
            adapter.L2_GAS_PRICE(),
            abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", bytes32(0), bytes32(0))
        );

        uint256 gatewayBalanceBefore = address(gatewayRouter).balance;

        // Execute
        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );

        uint256 gatewayBalanceAfter = address(gatewayRouter).balance;
        uint256 expectedEth = adapter.L2_MAX_SUBMISSION_COST() +
            adapter.L2_GAS_PRICE() *
            adapter.RELAY_TOKENS_L2_GAS_LIMIT();
        assertEq(gatewayBalanceAfter - gatewayBalanceBefore, expectedEth, "GatewayRouter balance change mismatch");

        // Verify allowance was set (HubPool approved gateway via delegatecall context)
        assertEq(
            fixture.dai.allowance(address(fixture.hubPool), gateway),
            TOKENS_TO_SEND,
            "Gateway allowance mismatch"
        );
    }

    // ============ relayTokens Tests (USDC via CCTP) ============

    function test_relayTokens_USDC_ViaCCTP() public {
        uint256 usdcAmount = 100e6; // 100 USDC (6 decimals)
        addLiquidity(fixture.usdc, usdcAmount);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            ARBITRUM_CHAIN_ID,
            address(fixture.usdc),
            usdcAmount,
            10e6 // LP fees
        );

        proposeAndExecuteBundle(root, bytes32(0), bytes32(0));

        bytes32 expectedRecipient = bytes32(uint256(uint160(mockSpoke)));

        vm.expectEmit(true, true, true, true, address(cctpMessenger));
        emit MockCCTPMessenger.DepositForBurnCalled(
            usdcAmount,
            ARBITRUM_CIRCLE_DOMAIN,
            expectedRecipient,
            address(fixture.usdc)
        );

        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );

        // Verify CCTP messenger allowance
        assertEq(
            fixture.usdc.allowance(address(fixture.hubPool), address(cctpMessenger)),
            usdcAmount,
            "CCTP allowance mismatch"
        );
    }

    function test_relayTokens_USDC_SplitsWhenOverLimit() public {
        uint256 usdcAmount = 100e6;
        addLiquidity(fixture.usdc, usdcAmount * 2);

        // 1) Set limit below amount to send and where amount does not divide evenly into limit.
        uint256 burnLimit = usdcAmount / 2 - 1;
        cctpMinter.setBurnLimit(burnLimit);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            ARBITRUM_CHAIN_ID,
            address(fixture.usdc),
            usdcAmount,
            10e6
        );

        proposeAndExecuteBundle(root, bytes32(0), bytes32(0));

        bytes32 expectedRecipient = bytes32(uint256(uint160(mockSpoke)));

        // Expect 3 calls: 2 * burnLimit + remainder
        vm.expectEmit(true, true, true, true, address(cctpMessenger));
        emit MockCCTPMessenger.DepositForBurnCalled(
            burnLimit,
            ARBITRUM_CIRCLE_DOMAIN,
            expectedRecipient,
            address(fixture.usdc)
        );

        vm.expectEmit(true, true, true, true, address(cctpMessenger));
        emit MockCCTPMessenger.DepositForBurnCalled(
            burnLimit,
            ARBITRUM_CIRCLE_DOMAIN,
            expectedRecipient,
            address(fixture.usdc)
        );

        vm.expectEmit(true, true, true, true, address(cctpMessenger));
        emit MockCCTPMessenger.DepositForBurnCalled(
            2,
            ARBITRUM_CIRCLE_DOMAIN,
            expectedRecipient,
            address(fixture.usdc)
        );

        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );

        // Should have called depositForBurn 3 times (2 full + 1 remainder)
        assertEq(cctpMessenger.depositForBurnCallCount(), 3, "Should split into 3 CCTP calls");

        // 2) Set limit below amount to send and where amount divides evenly into limit.
        proposeAndExecuteBundle(root, bytes32(0), bytes32(0));

        uint256 newLimit = usdcAmount / 2;
        cctpMinter.setBurnLimit(newLimit);

        // Expect 2 more calls: 2 * newLimit
        vm.expectEmit(true, true, true, true, address(cctpMessenger));
        emit MockCCTPMessenger.DepositForBurnCalled(
            newLimit,
            ARBITRUM_CIRCLE_DOMAIN,
            expectedRecipient,
            address(fixture.usdc)
        );

        vm.expectEmit(true, true, true, true, address(cctpMessenger));
        emit MockCCTPMessenger.DepositForBurnCalled(
            newLimit,
            ARBITRUM_CIRCLE_DOMAIN,
            expectedRecipient,
            address(fixture.usdc)
        );

        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );

        // 2 more calls added to prior 3.
        assertEq(cctpMessenger.depositForBurnCallCount(), 5, "Should have 5 total CCTP calls");
    }

    // ============ relayTokens Tests (USDT via OFT) ============

    function test_relayTokens_USDT_ViaOFT() public {
        uint256 usdtAmount = 100e6;
        addLiquidity(fixture.usdt, usdtAmount);

        // Configure OFT messenger in AdapterStore
        adapterStore.setMessenger(
            MessengerTypes.OFT_MESSENGER,
            ARBITRUM_OFT_EID,
            address(fixture.usdt),
            address(oftMessenger)
        );

        // Set fees to return (within cap)
        uint256 nativeFee = 0.1 ether;
        oftMessenger.setFeesToReturn(nativeFee, 0);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            ARBITRUM_CHAIN_ID,
            address(fixture.usdt),
            usdtAmount,
            10e6
        );

        proposeAndExecuteBundle(root, bytes32(0), bytes32(0));

        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );

        // Verify OFT messenger was called
        assertEq(oftMessenger.sendCallCount(), 1, "OFT send should be called once");

        // Verify send params (public struct getter returns tuple)
        (uint32 dstEid, bytes32 to, uint256 amountLD, , , , ) = oftMessenger.lastSendParam();
        assertEq(dstEid, ARBITRUM_OFT_EID, "Destination EID mismatch");
        assertEq(amountLD, usdtAmount, "Amount mismatch");
        assertEq(to, bytes32(uint256(uint160(mockSpoke))), "Recipient mismatch");

        // Verify allowance was set
        assertEq(
            fixture.usdt.allowance(address(fixture.hubPool), address(oftMessenger)),
            usdtAmount,
            "OFT allowance mismatch"
        );
    }

    // ============ OFT Error Cases ============

    function test_relayTokens_OFT_RevertIf_LzTokenFeeNotZero() public {
        uint256 usdtAmount = 100e6;
        addLiquidity(fixture.usdt, usdtAmount);

        adapterStore.setMessenger(
            MessengerTypes.OFT_MESSENGER,
            ARBITRUM_OFT_EID,
            address(fixture.usdt),
            address(oftMessenger)
        );

        // Set non-zero lzTokenFee
        oftMessenger.setFeesToReturn(0.1 ether, 1);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            ARBITRUM_CHAIN_ID,
            address(fixture.usdt),
            usdtAmount,
            10e6
        );

        proposeAndExecuteBundle(root, bytes32(0), bytes32(0));

        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
        vm.expectRevert();
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );
    }

    function test_relayTokens_OFT_RevertIf_NativeFeeExceedsCap() public {
        uint256 usdtAmount = 100e6;
        addLiquidity(fixture.usdt, usdtAmount);

        adapterStore.setMessenger(
            MessengerTypes.OFT_MESSENGER,
            ARBITRUM_OFT_EID,
            address(fixture.usdt),
            address(oftMessenger)
        );

        // Set native fee higher than cap (1 ether)
        oftMessenger.setFeesToReturn(2 ether, 0);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            ARBITRUM_CHAIN_ID,
            address(fixture.usdt),
            usdtAmount,
            10e6
        );

        proposeAndExecuteBundle(root, bytes32(0), bytes32(0));

        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
        vm.expectRevert();
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );
    }

    function test_relayTokens_OFT_RevertIf_InsufficientEthForFee() public {
        uint256 usdtAmount = 100e6;
        addLiquidity(fixture.usdt, usdtAmount);

        adapterStore.setMessenger(
            MessengerTypes.OFT_MESSENGER,
            ARBITRUM_OFT_EID,
            address(fixture.usdt),
            address(oftMessenger)
        );

        // Set a valid fee within cap
        oftMessenger.setFeesToReturn(0.5 ether, 0);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            ARBITRUM_CHAIN_ID,
            address(fixture.usdt),
            usdtAmount,
            10e6
        );

        proposeAndExecuteBundle(root, bytes32(0), bytes32(0));

        // Drain HubPool's ETH balance (leave 1 wei to avoid zero balance issues)
        uint256 hubPoolBalance = address(fixture.hubPool).balance;
        vm.prank(address(fixture.hubPool));
        (bool success, ) = address(this).call{ value: hubPoolBalance - 1 }("");
        require(success, "ETH transfer failed");

        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
        vm.expectRevert();
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );
    }

    function test_relayTokens_OFT_RevertIf_IncorrectAmountReceived() public {
        uint256 usdtAmount = 100e6;
        addLiquidity(fixture.usdt, usdtAmount);

        adapterStore.setMessenger(
            MessengerTypes.OFT_MESSENGER,
            ARBITRUM_OFT_EID,
            address(fixture.usdt),
            address(oftMessenger)
        );

        oftMessenger.setFeesToReturn(0, 0);
        // Set mismatched amounts in receipt (amountSentLD correct, amountReceivedLD wrong)
        oftMessenger.setLDAmountsToReturn(usdtAmount, usdtAmount - 1);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            ARBITRUM_CHAIN_ID,
            address(fixture.usdt),
            usdtAmount,
            10e6
        );

        proposeAndExecuteBundle(root, bytes32(0), bytes32(0));

        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
        vm.expectRevert();
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );
    }

    function test_relayTokens_OFT_RevertIf_IncorrectAmountSent() public {
        uint256 usdtAmount = 100e6;
        addLiquidity(fixture.usdt, usdtAmount);

        adapterStore.setMessenger(
            MessengerTypes.OFT_MESSENGER,
            ARBITRUM_OFT_EID,
            address(fixture.usdt),
            address(oftMessenger)
        );

        oftMessenger.setFeesToReturn(0, 0);
        // Set mismatched sent amount in receipt (amountSentLD wrong, amountReceivedLD correct)
        oftMessenger.setLDAmountsToReturn(usdtAmount - 1, usdtAmount);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            ARBITRUM_CHAIN_ID,
            address(fixture.usdt),
            usdtAmount,
            10e6
        );

        proposeAndExecuteBundle(root, bytes32(0), bytes32(0));

        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
        vm.expectRevert();
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );
    }

    // ============ Receive ETH ============

    receive() external payable {}
}
