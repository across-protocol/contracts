// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

// Test utilities
import { HubPoolTestBase } from "../../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../../utils/MerkleTreeUtils.sol";

// Contract under test
import { Arbitrum_Adapter } from "../../../../../contracts/chain-adapters/Arbitrum_Adapter.sol";
import { HubPoolInterface } from "../../../../../contracts/interfaces/HubPoolInterface.sol";

// External dependencies
import { ITokenMessenger } from "../../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { ArbitrumInboxLike, ArbitrumL1ERC20GatewayLike } from "../../../../../contracts/interfaces/ArbitrumBridge.sol";

// Existing mocks
import { ArbitrumMockErc20GatewayRouter, Inbox } from "../../../../../contracts/test/ArbitrumMocks.sol";
import { MockCCTPMessenger, MockCCTPMinter } from "../../../../../contracts/test/MockCCTP.sol";
import { MockOFTMessenger } from "../../../../../contracts/test/MockOFTMessenger.sol";
import { AdapterStore, MessengerTypes } from "../../../../../contracts/AdapterStore.sol";
import { MintableERC20 } from "../../../../../contracts/test/MockERC20.sol";

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

        // Verify createRetryableTicket was called exactly once
        assertEq(inbox.createRetryableTicketCallCount(), 1, "createRetryableTicket should be called once");

        // Verify createRetryableTicket was called with correct parameters
        (
            address destAddr,
            uint256 l2CallValue,
            uint256 maxSubmissionCost,
            address excessFeeRefundAddress,
            address callValueRefundAddress,
            uint256 maxGas,
            uint256 gasPriceBid,
            bytes memory data
        ) = inbox.lastCreateRetryableTicketCall();

        assertEq(destAddr, mockSpoke, "destAddr mismatch");
        assertEq(l2CallValue, 0, "l2CallValue mismatch");
        assertEq(maxSubmissionCost, adapter.L2_MAX_SUBMISSION_COST(), "maxSubmissionCost mismatch");
        assertEq(excessFeeRefundAddress, refundAddress, "excessFeeRefundAddress mismatch");
        assertEq(callValueRefundAddress, refundAddress, "callValueRefundAddress mismatch");
        assertEq(maxGas, adapter.RELAY_MESSAGE_L2_GAS_LIMIT(), "maxGas mismatch");
        assertEq(gasPriceBid, adapter.L2_GAS_PRICE(), "gasPriceBid mismatch");
        assertEq(data, functionData, "data mismatch");
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

        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

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

        // Verify outboundTransferCustomRefund was called exactly once
        assertEq(
            gatewayRouter.outboundTransferCustomRefundCallCount(),
            1,
            "outboundTransferCustomRefund should be called once"
        );

        // Verify outboundTransferCustomRefund was called with correct parameters
        {
            (
                address l1Token,
                address refundTo,
                address to,
                uint256 amount,
                uint256 maxGas,
                uint256 gasPriceBid,
                bytes memory data
            ) = gatewayRouter.lastOutboundTransferCustomRefundCall();

            assertEq(l1Token, address(fixture.dai), "l1Token mismatch");
            assertEq(refundTo, refundAddress, "refundTo mismatch");
            assertEq(to, mockSpoke, "to mismatch");
            assertEq(amount, TOKENS_TO_SEND, "amount mismatch");
            assertEq(maxGas, adapter.RELAY_TOKENS_L2_GAS_LIMIT(), "maxGas mismatch");
            assertEq(gasPriceBid, adapter.L2_GAS_PRICE(), "gasPriceBid mismatch");
            assertEq(data, expectedData, "data mismatch");
        }

        // Verify allowance was set (HubPool approved gateway via delegatecall context)
        assertEq(
            fixture.dai.allowance(address(fixture.hubPool), gateway),
            TOKENS_TO_SEND,
            "Gateway allowance mismatch"
        );

        // Verify createRetryableTicket was called exactly once (for relayRootBundle message)
        assertEq(inbox.createRetryableTicketCallCount(), 1, "createRetryableTicket should be called once");

        // Verify createRetryableTicket was called with correct parameters for relayRootBundle
        {
            (
                address destAddr,
                uint256 l2CallValue,
                uint256 maxSubmissionCost,
                address excessFeeRefundAddress,
                address callValueRefundAddress,
                uint256 maxGas,
                uint256 gasPriceBid,
                bytes memory data
            ) = inbox.lastCreateRetryableTicketCall();

            assertEq(destAddr, mockSpoke, "destAddr mismatch");
            assertEq(l2CallValue, 0, "l2CallValue mismatch");
            assertEq(maxSubmissionCost, adapter.L2_MAX_SUBMISSION_COST(), "maxSubmissionCost mismatch");
            assertEq(excessFeeRefundAddress, refundAddress, "excessFeeRefundAddress mismatch");
            assertEq(callValueRefundAddress, refundAddress, "callValueRefundAddress mismatch");
            assertEq(maxGas, adapter.RELAY_MESSAGE_L2_GAS_LIMIT(), "maxGas mismatch");
            assertEq(gasPriceBid, adapter.L2_GAS_PRICE(), "gasPriceBid mismatch");
            assertEq(
                data,
                abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", bytes32(0), bytes32(0)),
                "data mismatch"
            );
        }
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

        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

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

        // Verify depositForBurn was called exactly once
        assertEq(cctpMessenger.depositForBurnCallCount(), 1, "depositForBurn should be called once");

        // Verify depositForBurn was called with correct parameters
        (uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken) = cctpMessenger
            .lastDepositForBurnCall();

        assertEq(amount, usdcAmount, "amount mismatch");
        assertEq(destinationDomain, ARBITRUM_CIRCLE_DOMAIN, "destinationDomain mismatch");
        assertEq(mintRecipient, expectedRecipient, "mintRecipient mismatch");
        assertEq(burnToken, address(fixture.usdc), "burnToken mismatch");
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

        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

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

        // Verify each call's parameters (smock's atCall behavior)
        {
            (uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken) = cctpMessenger
                .getDepositForBurnCall(0);
            assertEq(amount, burnLimit, "Call 0: amount mismatch");
            assertEq(destinationDomain, ARBITRUM_CIRCLE_DOMAIN, "Call 0: destinationDomain mismatch");
            assertEq(mintRecipient, expectedRecipient, "Call 0: mintRecipient mismatch");
            assertEq(burnToken, address(fixture.usdc), "Call 0: burnToken mismatch");
        }
        {
            (uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken) = cctpMessenger
                .getDepositForBurnCall(1);
            assertEq(amount, burnLimit, "Call 1: amount mismatch");
            assertEq(destinationDomain, ARBITRUM_CIRCLE_DOMAIN, "Call 1: destinationDomain mismatch");
            assertEq(mintRecipient, expectedRecipient, "Call 1: mintRecipient mismatch");
            assertEq(burnToken, address(fixture.usdc), "Call 1: burnToken mismatch");
        }
        {
            (uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken) = cctpMessenger
                .getDepositForBurnCall(2);
            assertEq(amount, 2, "Call 2: amount mismatch (remainder)");
            assertEq(destinationDomain, ARBITRUM_CIRCLE_DOMAIN, "Call 2: destinationDomain mismatch");
            assertEq(mintRecipient, expectedRecipient, "Call 2: mintRecipient mismatch");
            assertEq(burnToken, address(fixture.usdc), "Call 2: burnToken mismatch");
        }

        // 2) Set limit below amount to send and where amount divides evenly into limit.
        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

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

        // Verify the additional calls' parameters
        {
            (uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken) = cctpMessenger
                .getDepositForBurnCall(3);
            assertEq(amount, newLimit, "Call 3: amount mismatch");
            assertEq(destinationDomain, ARBITRUM_CIRCLE_DOMAIN, "Call 3: destinationDomain mismatch");
            assertEq(mintRecipient, expectedRecipient, "Call 3: mintRecipient mismatch");
            assertEq(burnToken, address(fixture.usdc), "Call 3: burnToken mismatch");
        }
        {
            (uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken) = cctpMessenger
                .getDepositForBurnCall(4);
            assertEq(amount, newLimit, "Call 4: amount mismatch");
            assertEq(destinationDomain, ARBITRUM_CIRCLE_DOMAIN, "Call 4: destinationDomain mismatch");
            assertEq(mintRecipient, expectedRecipient, "Call 4: mintRecipient mismatch");
            assertEq(burnToken, address(fixture.usdc), "Call 4: burnToken mismatch");
        }
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

        // Set fees to return (within cap) - matches Hardhat test: 1 GWEI gas price * 200,000 gas cost
        uint256 nativeFee = 1 gwei * 200_000;
        oftMessenger.setFeesToReturn(nativeFee, 0);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            ARBITRUM_CHAIN_ID,
            address(fixture.usdt),
            usdtAmount,
            10e6
        );

        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

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

        // Verify OFT messenger was called exactly once
        assertEq(oftMessenger.sendCallCount(), 1, "OFT send should be called once");

        // Verify allowance was set (HubPool approved OFT messenger via delegatecall context)
        assertEq(
            fixture.usdt.allowance(address(fixture.hubPool), address(oftMessenger)),
            usdtAmount,
            "OFT allowance mismatch"
        );

        // Verify complete sendParam struct (matches Hardhat test's sendParam verification)
        bytes32 expectedRecipient = bytes32(uint256(uint160(mockSpoke)));
        {
            (
                uint32 dstEid,
                bytes32 to,
                uint256 amountLD,
                uint256 minAmountLD,
                bytes memory extraOptions,
                bytes memory composeMsg,
                bytes memory oftCmd
            ) = oftMessenger.lastSendParam();

            assertEq(dstEid, ARBITRUM_OFT_EID, "sendParam.dstEid mismatch");
            assertEq(to, expectedRecipient, "sendParam.to mismatch");
            assertEq(amountLD, usdtAmount, "sendParam.amountLD mismatch");
            assertEq(minAmountLD, usdtAmount, "sendParam.minAmountLD mismatch");
            assertEq(extraOptions, "", "sendParam.extraOptions should be empty");
            assertEq(composeMsg, "", "sendParam.composeMsg should be empty");
            assertEq(oftCmd, "", "sendParam.oftCmd should be empty");
        }

        // Verify fee struct was passed correctly
        {
            (uint256 feeNativeFee, uint256 feeLzTokenFee) = oftMessenger.lastFee();
            assertEq(feeNativeFee, nativeFee, "fee.nativeFee mismatch");
            assertEq(feeLzTokenFee, 0, "fee.lzTokenFee mismatch");
        }

        // Verify refund address was set to HubPool (caller via delegatecall)
        assertEq(oftMessenger.lastRefundAddress(), address(fixture.hubPool), "refundAddress mismatch");
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

        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

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

        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

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

        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

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

        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

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

        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

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
