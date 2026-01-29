// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HubPoolTestBase, MockStore } from "../utils/HubPoolTestBase.sol";

import { BondToken, ExtendedHubPoolInterface } from "../../../../contracts/BondToken.sol";
import { HubPool } from "../../../../contracts/HubPool.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { Mock_Adapter, Mock_Bridge } from "../../../../contracts/chain-adapters/Mock_Adapter.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/**
 * @title BondToken_E2ETest
 * @notice Foundry tests for BondToken interactions with HubPool.
 * @dev Migrated from test/evm/hardhat/BondToken.e2e.ts
 */
contract BondToken_E2ETest is HubPoolTestBase {
    // ============ Events ============

    event ProposerModified(address proposer, bool enabled);
    event BondSet(address indexed newBondToken, uint256 newBondAmount);
    event ProposeRootBundle(
        uint32 challengePeriodEndTimestamp,
        uint8 poolRebalanceLeafCount,
        uint256[] bundleEvaluationBlockNumbers,
        bytes32 indexed poolRebalanceRoot,
        bytes32 indexed relayerRefundRoot,
        bytes32 slowRelayRoot,
        address indexed proposer
    );
    event RootBundleDisputed(address indexed disputer, uint256 requestTime);

    // ============ State ============

    BondToken public bondToken;
    Mock_Adapter mockAdapter;
    address mockSpoke;

    address owner;
    address dataworker;
    address other;
    address lp;

    // ============ Constants ============

    uint256 constant WETH_TO_SEND = 100 ether;
    uint256 constant DAI_TO_SEND = 1000 ether;
    uint256 constant WETH_LP_FEE = 1 ether;
    uint256 constant DAI_LP_FEE = 10 ether;

    // ============ Setup ============

    function setUp() public {
        // Create base fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        owner = address(this);
        dataworker = makeAddr("dataworker");
        other = makeAddr("other");
        lp = makeAddr("lp");

        // Deploy BondToken with HubPool as target
        bondToken = new BondToken(ExtendedHubPoolInterface(address(fixture.hubPool)));

        // Whitelist bondToken as collateral for UMA
        fixture.addressWhitelist.addToWhitelist(address(bondToken));

        // Note: No finalFee is set for bondToken
        // This means totalBond = bondAmount when using bondToken

        // Pre-seed the dataworker with bondToken (they always need it)
        _seedBondToken(dataworker, BOND_AMOUNT * 3);

        // Configure HubPool bond to use BondToken
        // Since finalFee is 0, the emitted bondAmount equals BOND_AMOUNT
        vm.expectEmit(true, true, true, true);
        emit BondSet(address(bondToken), BOND_AMOUNT);
        fixture.hubPool.setBond(IERC20(address(bondToken)), BOND_AMOUNT);

        // Set approvals with headroom for dataworker and other
        vm.prank(dataworker);
        bondToken.approve(address(fixture.hubPool), TOTAL_BOND * 5);
        vm.prank(other);
        bondToken.approve(address(fixture.hubPool), TOTAL_BOND * 5);

        // Pre-approve dataworker as a proposer
        vm.expectEmit(true, true, true, true);
        emit ProposerModified(dataworker, true);
        bondToken.setProposer(dataworker, true);
        assertTrue(bondToken.proposers(dataworker));

        // Deploy Mock_Adapter and set up cross-chain contracts for execute test
        mockAdapter = new Mock_Adapter();
        mockSpoke = makeAddr("mockSpoke");
        fixture.hubPool.setCrossChainContracts(REPAYMENT_CHAIN_ID, address(mockAdapter), mockSpoke);

        // Enable tokens and set pool rebalance routes
        enableToken(REPAYMENT_CHAIN_ID, address(fixture.weth), fixture.l2Weth);
        enableToken(REPAYMENT_CHAIN_ID, address(fixture.dai), fixture.l2Dai);
    }

    // ============ Helper Functions ============

    /**
     * @notice Seeds an address with BondToken by depositing ETH.
     */
    function _seedBondToken(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        bondToken.deposit{ value: amount }();
    }

    /**
     * @notice Proposes a mock root bundle from the dataworker.
     */
    function _proposeRootBundle() internal {
        uint256[] memory bundleEvaluationBlockNumbers = new uint256[](1);
        bundleEvaluationBlockNumbers[0] = 1;

        vm.prank(dataworker);
        fixture.hubPool.proposeRootBundle(
            bundleEvaluationBlockNumbers,
            5, // poolRebalanceLeafCount
            MOCK_POOL_REBALANCE_ROOT,
            MOCK_RELAYER_REFUND_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );
    }

    /**
     * @notice Proposes a root bundle from a specific address.
     */
    function _proposeRootBundleFrom(address proposer) internal {
        uint256[] memory bundleEvaluationBlockNumbers = new uint256[](1);
        bundleEvaluationBlockNumbers[0] = 1;

        vm.prank(proposer);
        fixture.hubPool.proposeRootBundle(
            bundleEvaluationBlockNumbers,
            5, // poolRebalanceLeafCount
            MOCK_POOL_REBALANCE_ROOT,
            MOCK_RELAYER_REFUND_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );
    }

    /**
     * @notice Constructs a simple 2-leaf merkle tree for execute tests.
     */
    function _constructSimpleTree()
        internal
        view
        returns (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root)
    {
        leaves = new HubPoolInterface.PoolRebalanceLeaf[](2);

        // Leaf 0: Contains WETH and DAI, groupIndex = 0
        {
            uint256[] memory bundleLpFees = new uint256[](2);
            bundleLpFees[0] = WETH_LP_FEE;
            bundleLpFees[1] = DAI_LP_FEE;

            int256[] memory netSendAmounts = new int256[](2);
            netSendAmounts[0] = int256(WETH_TO_SEND);
            netSendAmounts[1] = int256(DAI_TO_SEND);

            int256[] memory runningBalances = new int256[](2);
            runningBalances[0] = int256(WETH_TO_SEND);
            runningBalances[1] = int256(DAI_TO_SEND);

            address[] memory l1Tokens = new address[](2);
            l1Tokens[0] = address(fixture.weth);
            l1Tokens[1] = address(fixture.dai);

            leaves[0] = HubPoolInterface.PoolRebalanceLeaf({
                chainId: REPAYMENT_CHAIN_ID,
                groupIndex: 0,
                bundleLpFees: bundleLpFees,
                netSendAmounts: netSendAmounts,
                runningBalances: runningBalances,
                leafId: 0,
                l1Tokens: l1Tokens
            });
        }

        // Leaf 1: Empty leaf, groupIndex = 1 (will not relay root bundle)
        {
            leaves[1] = HubPoolInterface.PoolRebalanceLeaf({
                chainId: REPAYMENT_CHAIN_ID,
                groupIndex: 1,
                bundleLpFees: new uint256[](0),
                netSendAmounts: new int256[](0),
                runningBalances: new int256[](0),
                leafId: 1,
                l1Tokens: new address[](0)
            });
        }

        root = _buildMerkleRoot(leaves);
    }

    function _buildMerkleRoot(HubPoolInterface.PoolRebalanceLeaf[] memory leaves) internal pure returns (bytes32) {
        bytes32 leaf0Hash = keccak256(abi.encode(leaves[0]));
        bytes32 leaf1Hash = keccak256(abi.encode(leaves[1]));
        if (leaf0Hash < leaf1Hash) {
            return keccak256(abi.encodePacked(leaf0Hash, leaf1Hash));
        } else {
            return keccak256(abi.encodePacked(leaf1Hash, leaf0Hash));
        }
    }

    function _getMerkleProof(
        HubPoolInterface.PoolRebalanceLeaf[] memory leaves,
        uint256 index
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory proof = new bytes32[](1);
        uint256 siblingIndex = index == 0 ? 1 : 0;
        proof[0] = keccak256(abi.encode(leaves[siblingIndex]));
        return proof;
    }

    // ============ Tests ============

    /**
     * @notice Test that disallowed proposers cannot submit proposals.
     */
    function test_DisallowedProposersCannotSubmitProposals() public {
        uint256 hubPoolBal = bondToken.balanceOf(address(fixture.hubPool));
        uint256 dataworkerBal = bondToken.balanceOf(dataworker);

        // Disallow the dataworker as a proposer
        vm.expectEmit(true, true, true, true);
        emit ProposerModified(dataworker, false);
        bondToken.setProposer(dataworker, false);
        assertFalse(bondToken.proposers(dataworker));

        // Proposal should fail; balances unchanged
        vm.expectRevert("Transfer not permitted");
        _proposeRootBundleFrom(dataworker);

        assertEq(bondToken.balanceOf(address(fixture.hubPool)), hubPoolBal);
        assertEq(bondToken.balanceOf(dataworker), dataworkerBal);
    }

    /**
     * @notice Test that allowed proposers can submit proposals to the HubPool.
     */
    function test_AllowedProposersCanSubmitProposals() public {
        uint256 hubPoolBal = bondToken.balanceOf(address(fixture.hubPool));
        uint256 dataworkerBal = bondToken.balanceOf(dataworker);

        // Dataworker is already enabled as proposer in setUp, verify it
        assertTrue(bondToken.proposers(dataworker));

        // Proposal successful; bondAmount is transferred from proposer to HubPool
        _proposeRootBundle();

        (, , , , address proposer, , ) = fixture.hubPool.rootBundleProposal();
        assertEq(proposer, dataworker);
        assertEq(bondToken.balanceOf(address(fixture.hubPool)), hubPoolBal + BOND_AMOUNT);
        assertEq(bondToken.balanceOf(dataworker), dataworkerBal - BOND_AMOUNT);
    }

    /**
     * @notice Test that bonds from undisputed proposals can be refunded to the proposer.
     * @dev This test is similar to HubPool.executeRootBundle() but uses the custom bond token.
     */
    function test_BondsFromUndisputedProposalsCanBeRefunded() public {
        // Seed LP with tokens
        seedUserWithWeth(lp, AMOUNT_TO_LP * 10);
        fixture.dai.mint(lp, AMOUNT_TO_LP * 10);

        // Add liquidity for WETH
        vm.prank(lp);
        fixture.weth.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        vm.prank(lp);
        fixture.hubPool.addLiquidity(address(fixture.weth), AMOUNT_TO_LP);

        // Add liquidity for DAI
        vm.prank(lp);
        fixture.dai.approve(address(fixture.hubPool), AMOUNT_TO_LP * 10);
        vm.prank(lp);
        fixture.hubPool.addLiquidity(address(fixture.dai), AMOUNT_TO_LP * 10);

        // Construct merkle tree
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = _constructSimpleTree();

        // Propose root bundle
        uint256[] memory bundleEvaluationBlockNumbers = new uint256[](2);
        bundleEvaluationBlockNumbers[0] = 3117;
        bundleEvaluationBlockNumbers[1] = 3118;

        vm.prank(dataworker);
        fixture.hubPool.proposeRootBundle(
            bundleEvaluationBlockNumbers,
            2,
            root,
            MOCK_RELAYER_REFUND_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );

        // Advance time past liveness
        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        // Execute first leaf
        vm.prank(dataworker);
        fixture.hubPool.executeRootBundle(
            leaves[0].chainId,
            leaves[0].groupIndex,
            leaves[0].bundleLpFees,
            leaves[0].netSendAmounts,
            leaves[0].runningBalances,
            leaves[0].leafId,
            leaves[0].l1Tokens,
            _getMerkleProof(leaves, 0)
        );

        // Record balances before second execution
        uint256 dataworkerBalBefore = bondToken.balanceOf(dataworker);
        uint256 hubPoolBalBefore = bondToken.balanceOf(address(fixture.hubPool));

        // Second execution sends bond back to data worker
        vm.prank(dataworker);
        fixture.hubPool.executeRootBundle(
            leaves[1].chainId,
            leaves[1].groupIndex,
            leaves[1].bundleLpFees,
            leaves[1].netSendAmounts,
            leaves[1].runningBalances,
            leaves[1].leafId,
            leaves[1].l1Tokens,
            _getMerkleProof(leaves, 1)
        );

        // Verify bond was returned (finalFee is 0 for bondToken, so bond = BOND_AMOUNT)
        assertEq(bondToken.balanceOf(dataworker), dataworkerBalBefore + BOND_AMOUNT, "Dataworker should receive bond");
        assertEq(
            bondToken.balanceOf(address(fixture.hubPool)),
            hubPoolBalBefore - BOND_AMOUNT,
            "HubPool should release bond"
        );
    }

    /**
     * @notice Test that proposers can self-dispute.
     */
    function test_ProposersCanSelfDispute() public {
        _proposeRootBundle();

        vm.expectEmit(true, true, true, true, address(fixture.hubPool));
        emit RootBundleDisputed(dataworker, block.timestamp);

        vm.prank(dataworker);
        fixture.hubPool.disputeRootBundle();
    }

    /**
     * @notice Test that disallowed proposers can self-dispute.
     * @dev The pending root bundle is deleted before ABT transferFrom() is invoked.
     */
    function test_DisallowedProposersCanSelfDispute() public {
        _proposeRootBundle();

        // Disallow the proposer (with a pending proposal)
        vm.expectEmit(true, true, true, true);
        emit ProposerModified(dataworker, false);
        bondToken.setProposer(dataworker, false);

        // Proposer can still dispute
        vm.expectEmit(true, true, true, true, address(fixture.hubPool));
        emit RootBundleDisputed(dataworker, block.timestamp);

        vm.prank(dataworker);
        fixture.hubPool.disputeRootBundle();
    }

    /**
     * @notice Test that non-proposers can conditionally send ABT to the HubPool.
     */
    function test_NonProposersCanConditionallySendABTToHubPool() public {
        _seedBondToken(other, BOND_AMOUNT * 3);

        assertEq(bondToken.balanceOf(address(fixture.hubPool)), 0);
        assertEq(bondToken.balanceOf(other), BOND_AMOUNT * 3);

        // No pending proposal => transfer permitted
        vm.prank(other);
        bondToken.transfer(address(fixture.hubPool), BOND_AMOUNT);
        assertEq(bondToken.balanceOf(address(fixture.hubPool)), BOND_AMOUNT);
        assertEq(bondToken.balanceOf(other), BOND_AMOUNT * 2);

        // Pending proposal from a proposer => transfer permitted (emulates dispute)
        _proposeRootBundle();
        assertEq(bondToken.balanceOf(address(fixture.hubPool)), BOND_AMOUNT * 2);

        vm.prank(other);
        bondToken.transfer(address(fixture.hubPool), BOND_AMOUNT);
        assertEq(bondToken.balanceOf(address(fixture.hubPool)), BOND_AMOUNT * 3);
        assertEq(bondToken.balanceOf(other), BOND_AMOUNT);
    }

    /**
     * @notice Test that non-proposers cannot submit proposals to the HubPool.
     */
    function test_NonProposersCannotSubmitProposals() public {
        _seedBondToken(other, BOND_AMOUNT);
        assertEq(bondToken.balanceOf(other), BOND_AMOUNT);

        vm.expectRevert("Transfer not permitted");
        _proposeRootBundleFrom(other);
    }

    /**
     * @notice Test that non-proposers can dispute root bundle proposals.
     */
    function test_NonProposersCanDisputeRootBundleProposals() public {
        _seedBondToken(other, BOND_AMOUNT);
        assertEq(bondToken.balanceOf(other), BOND_AMOUNT);

        _proposeRootBundle();

        (, , , , address proposer, , ) = fixture.hubPool.rootBundleProposal();
        assertEq(proposer, dataworker);

        // Verify that other is not a proposer
        assertFalse(bondToken.proposers(other));

        // Non-proposer can dispute
        vm.expectEmit(true, true, true, true, address(fixture.hubPool));
        emit RootBundleDisputed(other, block.timestamp);

        vm.prank(other);
        fixture.hubPool.disputeRootBundle();
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
