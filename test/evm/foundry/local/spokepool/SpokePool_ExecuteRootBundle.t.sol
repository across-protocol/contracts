// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test, Vm, stdError } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { Merkle } from "lib/murky/src/Merkle.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { ExpandedERC20WithBlacklist } from "../../../../../contracts/test/ExpandedERC20WithBlacklist.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { SpokePoolInterface } from "../../../../../contracts/interfaces/SpokePoolInterface.sol";
import { V3SpokePoolInterface } from "../../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { AddressToBytes32 } from "../../../../../contracts/libraries/AddressConverters.sol";

contract SpokePoolExecuteRootBundleTest is Test {
    using AddressToBytes32 for address;

    MockSpokePool public spokePool;
    ExpandedERC20WithBlacklist public destErc20;
    WETH9 public weth;
    Merkle public merkle;

    address public owner;
    address public dataWorker;
    address public relayer;
    address public rando;

    uint256 public constant AMOUNT_TO_RELAY = 25e18;
    uint256 public constant AMOUNT_HELD_BY_POOL = AMOUNT_TO_RELAY * 4;
    uint256 public constant AMOUNT_TO_RETURN = 1e18;
    uint256 public constant DESTINATION_CHAIN_ID = 1342;

    bytes32 public constant MOCK_SLOW_RELAY_ROOT = keccak256("mockSlowRelayRoot");

    event ExecutedRelayerRefundRoot(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint256[] refundAmounts,
        uint32 indexed rootBundleId,
        uint32 indexed leafId,
        address l2TokenAddress,
        address[] refundAddresses,
        bool deferredRefunds,
        address caller
    );

    event TokensBridged(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint32 indexed leafId,
        bytes32 indexed l2TokenAddress,
        address caller
    );

    event BridgedToHubPool(uint256 amount, address token);

    function setUp() public {
        owner = makeAddr("owner");
        dataWorker = makeAddr("dataWorker");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");

        merkle = new Merkle();
        weth = new WETH9();

        // Deploy destErc20 with blacklist functionality
        destErc20 = new ExpandedERC20WithBlacklist("L2 USD Coin", "L2 USDC", 18);
        // Add this test contract as minter (Minter role = 1)
        destErc20.addMember(1, address(this));

        // Deploy SpokePool via proxy
        vm.startPrank(owner);
        MockSpokePool implementation = new MockSpokePool(address(weth));
        address proxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeCall(MockSpokePool.initialize, (0, owner, owner)))
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(DESTINATION_CHAIN_ID);
        vm.stopPrank();

        // Seed the SpokePool with tokens
        destErc20.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
    }

    // Helper to build relayer refund leaves
    function _buildRelayerRefundLeaves(
        uint256[] memory chainIds,
        uint256[] memory amountsToReturn,
        address[] memory l2Tokens,
        address[][] memory refundAddresses,
        uint256[][] memory refundAmounts
    ) internal pure returns (SpokePoolInterface.RelayerRefundLeaf[] memory leaves) {
        leaves = new SpokePoolInterface.RelayerRefundLeaf[](chainIds.length);
        for (uint256 i = 0; i < chainIds.length; i++) {
            leaves[i] = SpokePoolInterface.RelayerRefundLeaf({
                amountToReturn: amountsToReturn[i],
                chainId: chainIds[i],
                refundAmounts: refundAmounts[i],
                leafId: uint32(i),
                l2TokenAddress: l2Tokens[i],
                refundAddresses: refundAddresses[i]
            });
        }
    }

    // Helper to build merkle tree from leaves
    function _buildMerkleTree(
        SpokePoolInterface.RelayerRefundLeaf[] memory leaves
    ) internal view returns (bytes32 root, bytes32[] memory leafHashes) {
        leafHashes = new bytes32[](leaves.length);
        for (uint256 i = 0; i < leaves.length; i++) {
            leafHashes[i] = keccak256(abi.encode(leaves[i]));
        }
        root = merkle.getRoot(leafHashes);
    }

    // Helper to get proof for a leaf
    function _getProof(bytes32[] memory leafHashes, uint256 index) internal view returns (bytes32[] memory) {
        return merkle.getProof(leafHashes, index);
    }

    // Helper to construct a simple tree for testing
    function _constructSimpleTree()
        internal
        view
        returns (
            SpokePoolInterface.RelayerRefundLeaf[] memory leaves,
            uint256 leavesRefundAmount,
            bytes32 root,
            bytes32[] memory leafHashes
        )
    {
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = DESTINATION_CHAIN_ID;
        chainIds[1] = DESTINATION_CHAIN_ID;

        uint256[] memory amountsToReturn = new uint256[](2);
        amountsToReturn[0] = AMOUNT_TO_RETURN;
        amountsToReturn[1] = 0;

        address[] memory l2Tokens = new address[](2);
        l2Tokens[0] = address(destErc20);
        l2Tokens[1] = address(destErc20);

        address[][] memory refundAddrs = new address[][](2);
        refundAddrs[0] = new address[](2);
        refundAddrs[0][0] = relayer;
        refundAddrs[0][1] = rando;
        refundAddrs[1] = new address[](0);

        uint256[][] memory refundAmts = new uint256[][](2);
        refundAmts[0] = new uint256[](2);
        refundAmts[0][0] = AMOUNT_TO_RELAY;
        refundAmts[0][1] = AMOUNT_TO_RELAY;
        refundAmts[1] = new uint256[](0);

        leaves = _buildRelayerRefundLeaves(chainIds, amountsToReturn, l2Tokens, refundAddrs, refundAmts);

        // Calculate total refund amount
        leavesRefundAmount = AMOUNT_TO_RELAY * 2;

        (root, leafHashes) = _buildMerkleTree(leaves);
    }

    function testExecuteRelayerRefundRootSendsTokensToRecipients() public {
        (
            SpokePoolInterface.RelayerRefundLeaf[] memory leaves,
            uint256 leavesRefundAmount,
            bytes32 root,
            bytes32[] memory leafHashes
        ) = _constructSimpleTree();

        // Store new tree
        vm.prank(owner);
        spokePool.relayRootBundle(root, MOCK_SLOW_RELAY_ROOT);

        // Distribute the first leaf
        bytes32[] memory proof = _getProof(leafHashes, 0);
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaves[0], proof);

        // Relayers should be refunded
        assertEq(destErc20.balanceOf(address(spokePool)), AMOUNT_HELD_BY_POOL - leavesRefundAmount);
        assertEq(destErc20.balanceOf(relayer), AMOUNT_TO_RELAY);
        assertEq(destErc20.balanceOf(rando), AMOUNT_TO_RELAY);
    }

    function testExecuteRelayerRefundRootEmitsCorrectEvents() public {
        (
            SpokePoolInterface.RelayerRefundLeaf[] memory leaves,
            ,
            bytes32 root,
            bytes32[] memory leafHashes
        ) = _constructSimpleTree();

        // Store new tree
        vm.prank(owner);
        spokePool.relayRootBundle(root, MOCK_SLOW_RELAY_ROOT);

        // Prepare expected refund amounts array
        uint256[] memory expectedRefundAmounts = new uint256[](2);
        expectedRefundAmounts[0] = AMOUNT_TO_RELAY;
        expectedRefundAmounts[1] = AMOUNT_TO_RELAY;

        address[] memory expectedRefundAddresses = new address[](2);
        expectedRefundAddresses[0] = relayer;
        expectedRefundAddresses[1] = rando;

        // Events are emitted in order: TokensBridged, then ExecutedRelayerRefundRoot
        // Expect TokensBridged event first since amountToReturn > 0
        vm.expectEmit(true, true, true, true);
        emit TokensBridged(AMOUNT_TO_RETURN, DESTINATION_CHAIN_ID, 0, address(destErc20).toBytes32(), dataWorker);

        // Expect ExecutedRelayerRefundRoot event second
        vm.expectEmit(true, true, true, true);
        emit ExecutedRelayerRefundRoot(
            AMOUNT_TO_RETURN,
            DESTINATION_CHAIN_ID,
            expectedRefundAmounts,
            0, // rootBundleId
            0, // leafId
            address(destErc20),
            expectedRefundAddresses,
            false, // deferredRefunds
            dataWorker
        );

        bytes32[] memory proof = _getProof(leafHashes, 0);
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaves[0], proof);
    }

    function testNoTokensBridgedEventWhenAmountToReturnIsZero() public {
        (
            SpokePoolInterface.RelayerRefundLeaf[] memory leaves,
            ,
            bytes32 root,
            bytes32[] memory leafHashes
        ) = _constructSimpleTree();

        // Store new tree
        vm.prank(owner);
        spokePool.relayRootBundle(root, MOCK_SLOW_RELAY_ROOT);

        // Execute first leaf to allow executing second
        bytes32[] memory proof0 = _getProof(leafHashes, 0);
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaves[0], proof0);

        // Record logs for second leaf
        vm.recordLogs();
        bytes32[] memory proof1 = _getProof(leafHashes, 1);
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaves[1], proof1);

        // Check that TokensBridged was not emitted for the second leaf
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 tokensBridgedSelector = keccak256("TokensBridged(uint256,uint256,uint32,bytes32,address)");
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(entries[i].topics[0] != tokensBridgedSelector, "TokensBridged should not be emitted");
        }
    }

    function testExecutionRejectsInvalidLeaf() public {
        (
            SpokePoolInterface.RelayerRefundLeaf[] memory leaves,
            ,
            bytes32 root,
            bytes32[] memory leafHashes
        ) = _constructSimpleTree();

        vm.prank(owner);
        spokePool.relayRootBundle(root, MOCK_SLOW_RELAY_ROOT);

        // Modify the leaf to make it invalid (change amountToReturn, not chainId,
        // since chainId is checked before merkle proof)
        SpokePoolInterface.RelayerRefundLeaf memory badLeaf = leaves[0];
        badLeaf.amountToReturn = 999;

        bytes32[] memory proof = _getProof(leafHashes, 0);
        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InvalidMerkleProof.selector);
        spokePool.executeRelayerRefundLeaf(0, badLeaf, proof);
    }

    function testExecutionRejectsInvalidRootBundleIndex() public {
        (
            SpokePoolInterface.RelayerRefundLeaf[] memory leaves,
            ,
            bytes32 root,
            bytes32[] memory leafHashes
        ) = _constructSimpleTree();

        vm.prank(owner);
        spokePool.relayRootBundle(root, MOCK_SLOW_RELAY_ROOT);

        bytes32[] memory proof = _getProof(leafHashes, 0);
        vm.prank(dataWorker);
        // Root bundle index 1 doesn't exist - causes array out of bounds panic (0x32)
        vm.expectRevert(stdError.indexOOBError);
        spokePool.executeRelayerRefundLeaf(1, leaves[0], proof);
    }

    function testCannotRefundLeafWithWrongChainId() public {
        // Create tree for another chain ID
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 13371; // Wrong chain ID

        uint256[] memory amountsToReturn = new uint256[](1);
        amountsToReturn[0] = AMOUNT_TO_RETURN;

        address[] memory l2Tokens = new address[](1);
        l2Tokens[0] = address(destErc20);

        address[][] memory refundAddrs = new address[][](1);
        refundAddrs[0] = new address[](1);
        refundAddrs[0][0] = relayer;

        uint256[][] memory refundAmts = new uint256[][](1);
        refundAmts[0] = new uint256[](1);
        refundAmts[0][0] = AMOUNT_TO_RELAY;

        SpokePoolInterface.RelayerRefundLeaf[] memory leaves = _buildRelayerRefundLeaves(
            chainIds,
            amountsToReturn,
            l2Tokens,
            refundAddrs,
            refundAmts
        );

        // Need at least 2 leaves for merkle tree
        SpokePoolInterface.RelayerRefundLeaf[] memory leavesForTree = new SpokePoolInterface.RelayerRefundLeaf[](2);
        leavesForTree[0] = leaves[0];
        leavesForTree[1] = leaves[0];
        leavesForTree[1].leafId = 1;

        (bytes32 root, bytes32[] memory leafHashes) = _buildMerkleTree(leavesForTree);

        vm.prank(owner);
        spokePool.relayRootBundle(root, MOCK_SLOW_RELAY_ROOT);

        // Root is valid and leaf is contained in tree, but chain ID doesn't match pool's chain ID
        bytes32[] memory proof = _getProof(leafHashes, 0);
        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InvalidChainId.selector);
        spokePool.executeRelayerRefundLeaf(0, leavesForTree[0], proof);
    }

    function testExecutionRejectsDoubleClaimedLeaves() public {
        (
            SpokePoolInterface.RelayerRefundLeaf[] memory leaves,
            ,
            bytes32 root,
            bytes32[] memory leafHashes
        ) = _constructSimpleTree();

        vm.prank(owner);
        spokePool.relayRootBundle(root, MOCK_SLOW_RELAY_ROOT);

        // First claim should succeed
        bytes32[] memory proof = _getProof(leafHashes, 0);
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaves[0], proof);

        // Second claim should fail
        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.ClaimedMerkleLeaf.selector);
        spokePool.executeRelayerRefundLeaf(0, leaves[0], proof);
    }

    function testExecutionLogsDeferredRefunds() public {
        (
            SpokePoolInterface.RelayerRefundLeaf[] memory leaves,
            ,
            bytes32 root,
            bytes32[] memory leafHashes
        ) = _constructSimpleTree();

        // Store new tree
        vm.prank(owner);
        spokePool.relayRootBundle(root, MOCK_SLOW_RELAY_ROOT);

        // Blacklist the relayer to prevent it from receiving refunds
        destErc20.setBlacklistStatus(relayer, true);

        // Expect event with deferredRefunds = true
        uint256[] memory expectedRefundAmounts = new uint256[](2);
        expectedRefundAmounts[0] = AMOUNT_TO_RELAY;
        expectedRefundAmounts[1] = AMOUNT_TO_RELAY;

        address[] memory expectedRefundAddresses = new address[](2);
        expectedRefundAddresses[0] = relayer;
        expectedRefundAddresses[1] = rando;

        vm.expectEmit(true, true, true, true);
        emit ExecutedRelayerRefundRoot(
            AMOUNT_TO_RETURN,
            DESTINATION_CHAIN_ID,
            expectedRefundAmounts,
            0,
            0,
            address(destErc20),
            expectedRefundAddresses,
            true, // deferredRefunds should be true
            dataWorker
        );

        bytes32[] memory proof = _getProof(leafHashes, 0);
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaves[0], proof);

        // Only non-blacklisted recipient should receive their refund
        assertEq(destErc20.balanceOf(address(spokePool)), AMOUNT_HELD_BY_POOL - AMOUNT_TO_RELAY);
        assertEq(destErc20.balanceOf(relayer), 0);
        assertEq(destErc20.balanceOf(rando), AMOUNT_TO_RELAY);

        // Blacklisted relayer's refund should be tracked
        assertEq(spokePool.getRelayerRefund(address(destErc20), relayer), AMOUNT_TO_RELAY);
    }
}

contract DistributeRelayerRefundsTest is Test {
    using AddressToBytes32 for address;

    MockSpokePool public spokePool;
    ExpandedERC20WithBlacklist public destErc20;
    WETH9 public weth;

    address public owner;
    address public dataWorker;
    address public relayer;
    address public rando;

    uint256 public constant AMOUNT_TO_RELAY = 25e18;
    uint256 public constant AMOUNT_HELD_BY_POOL = AMOUNT_TO_RELAY * 4;
    uint256 public constant DESTINATION_CHAIN_ID = 1342;

    event TokensBridged(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint32 indexed leafId,
        bytes32 indexed l2TokenAddress,
        address caller
    );

    event BridgedToHubPool(uint256 amount, address token);

    function setUp() public {
        owner = makeAddr("owner");
        dataWorker = makeAddr("dataWorker");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");

        weth = new WETH9();

        // Deploy destErc20 with blacklist functionality
        destErc20 = new ExpandedERC20WithBlacklist("L2 USD Coin", "L2 USDC", 18);
        destErc20.addMember(1, address(this));

        // Deploy SpokePool via proxy
        vm.startPrank(owner);
        MockSpokePool implementation = new MockSpokePool(address(weth));
        address proxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeCall(MockSpokePool.initialize, (0, owner, owner)))
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(DESTINATION_CHAIN_ID);
        vm.stopPrank();

        // Seed the SpokePool with tokens
        destErc20.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
    }

    function testRefundAddressLengthMismatch() public {
        uint256[] memory refundAmounts = new uint256[](3);
        refundAmounts[0] = AMOUNT_TO_RELAY;
        refundAmounts[1] = AMOUNT_TO_RELAY;
        refundAmounts[2] = 0;

        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InvalidMerkleLeaf.selector);
        spokePool.distributeRelayerRefunds(
            DESTINATION_CHAIN_ID,
            1,
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );
    }

    function testAmountToReturnPositiveCallsBridgeTokensToHubPool() public {
        uint256[] memory refundAmounts = new uint256[](0);
        address[] memory refundAddresses = new address[](0);

        vm.expectEmit(true, true, true, true);
        emit BridgedToHubPool(1, address(destErc20));

        vm.prank(dataWorker);
        spokePool.distributeRelayerRefunds(
            DESTINATION_CHAIN_ID,
            1, // amountToReturn > 0
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );
    }

    function testAmountToReturnPositiveEmitsTokensBridged() public {
        uint256[] memory refundAmounts = new uint256[](0);
        address[] memory refundAddresses = new address[](0);

        vm.expectEmit(true, true, true, true);
        emit TokensBridged(1, DESTINATION_CHAIN_ID, 0, address(destErc20).toBytes32(), dataWorker);

        vm.prank(dataWorker);
        spokePool.distributeRelayerRefunds(
            DESTINATION_CHAIN_ID,
            1, // amountToReturn > 0
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );
    }

    function testAmountToReturnZeroDoesNotCallBridgeTokensToHubPool() public {
        uint256[] memory refundAmounts = new uint256[](0);
        address[] memory refundAddresses = new address[](0);

        vm.recordLogs();
        vm.prank(dataWorker);
        spokePool.distributeRelayerRefunds(
            DESTINATION_CHAIN_ID,
            0, // amountToReturn = 0
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 bridgedToHubPoolSelector = keccak256("BridgedToHubPool(uint256,address)");
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(entries[i].topics[0] != bridgedToHubPoolSelector, "BridgedToHubPool should not be emitted");
        }
    }

    function testAmountToReturnZeroDoesNotEmitTokensBridged() public {
        uint256[] memory refundAmounts = new uint256[](0);
        address[] memory refundAddresses = new address[](0);

        vm.recordLogs();
        vm.prank(dataWorker);
        spokePool.distributeRelayerRefunds(
            DESTINATION_CHAIN_ID,
            0, // amountToReturn = 0
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 tokensBridgedSelector = keccak256("TokensBridged(uint256,uint256,uint32,bytes32,address)");
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(entries[i].topics[0] != tokensBridgedSelector, "TokensBridged should not be emitted");
        }
    }

    function testSendsOneTransferPerNonzeroRefundAmount() public {
        uint256[] memory refundAmounts = new uint256[](3);
        refundAmounts[0] = AMOUNT_TO_RELAY;
        refundAmounts[1] = AMOUNT_TO_RELAY;
        refundAmounts[2] = 0; // Zero refund - should not trigger transfer

        address[] memory refundAddresses = new address[](3);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;
        refundAddresses[2] = rando;

        uint256 spokeBalanceBefore = destErc20.balanceOf(address(spokePool));
        uint256 relayerBalanceBefore = destErc20.balanceOf(relayer);
        uint256 randoBalanceBefore = destErc20.balanceOf(rando);

        vm.prank(dataWorker);
        spokePool.distributeRelayerRefunds(
            DESTINATION_CHAIN_ID,
            1, // amountToReturn > 0
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );

        // Check balance changes
        assertEq(destErc20.balanceOf(address(spokePool)), spokeBalanceBefore - AMOUNT_TO_RELAY * 2);
        assertEq(destErc20.balanceOf(relayer), relayerBalanceBefore + AMOUNT_TO_RELAY);
        assertEq(destErc20.balanceOf(rando), randoBalanceBefore + AMOUNT_TO_RELAY);
    }

    function testRefundsAlsoBridgeTokensIfAmountToReturnPositive() public {
        uint256[] memory refundAmounts = new uint256[](3);
        refundAmounts[0] = AMOUNT_TO_RELAY;
        refundAmounts[1] = AMOUNT_TO_RELAY;
        refundAmounts[2] = 0;

        address[] memory refundAddresses = new address[](3);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;
        refundAddresses[2] = rando;

        vm.expectEmit(true, true, true, true);
        emit BridgedToHubPool(1, address(destErc20));

        vm.prank(dataWorker);
        spokePool.distributeRelayerRefunds(
            DESTINATION_CHAIN_ID,
            1, // amountToReturn > 0
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );
    }

    function testRevertsWhenTotalRefundsExceedsBalance() public {
        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = AMOUNT_HELD_BY_POOL; // Total pool balance
        refundAmounts[1] = AMOUNT_TO_RELAY; // This would exceed balance

        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InsufficientSpokePoolBalanceToExecuteLeaf.selector);
        spokePool.distributeRelayerRefunds(
            DESTINATION_CHAIN_ID,
            1,
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );

        // No transfers should have happened
        assertEq(destErc20.balanceOf(address(spokePool)), AMOUNT_HELD_BY_POOL);
        assertEq(destErc20.balanceOf(relayer), 0);
        assertEq(destErc20.balanceOf(rando), 0);
    }
}
