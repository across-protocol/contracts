// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test, Vm } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { Merkle } from "lib/murky/src/Merkle.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ExpandedERC20 } from "../../../../../contracts/external/uma/core/contracts/common/implementation/ExpandedERC20.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../../../../../contracts/libraries/AddressConverters.sol";
import { V3SpokePoolInterface } from "../../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { SpokePoolInterface } from "../../../../../contracts/interfaces/SpokePoolInterface.sol";

contract SpokePoolSlowRelayTest is Test {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    MockSpokePool public spokePool;
    WETH9 public weth;
    ExpandedERC20 public erc20;
    ExpandedERC20 public destErc20;
    Merkle public merkle;

    address public owner;
    address public crossDomainAdmin;
    address public hubPool;
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

    bytes32 public constant MOCK_TREE_ROOT = keccak256("mockTreeRoot");

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

    event PreLeafExecuteHook(bytes32 token);

    function setUp() public {
        owner = makeAddr("owner");
        crossDomainAdmin = makeAddr("crossDomainAdmin");
        hubPool = makeAddr("hubPool");
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        relayer = makeAddr("relayer");

        weth = new WETH9();
        merkle = new Merkle();

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

        // Seed spoke pool with tokens for slow fills
        destErc20.mint(address(spokePool), AMOUNT_TO_SEED);

        // Seed relayer with tokens
        destErc20.mint(relayer, AMOUNT_TO_SEED);
        vm.prank(relayer);
        destErc20.approve(address(spokePool), type(uint256).max);
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

    function _hashNonEmptyMessage(bytes memory message) internal pure returns (bytes32) {
        return message.length > 0 ? keccak256(message) : bytes32(0);
    }

    function _buildSlowFillLeaf(
        V3SpokePoolInterface.V3RelayData memory relayData
    ) internal pure returns (V3SpokePoolInterface.V3SlowFill memory) {
        return
            V3SpokePoolInterface.V3SlowFill({
                relayData: relayData,
                chainId: DESTINATION_CHAIN_ID,
                updatedOutputAmount: relayData.outputAmount + 1 // Make updated output amount different
            });
    }

    function _hashSlowFillLeaf(V3SpokePoolInterface.V3SlowFill memory slowFillLeaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(slowFillLeaf));
    }

    function _buildSlowFillTree(
        V3SpokePoolInterface.V3SlowFill[] memory slowFillLeaves
    ) internal view returns (bytes32 root, bytes32[] memory leafHashes) {
        // Murky requires at least 2 leaves, so pad with a dummy leaf if needed
        uint256 numLeaves = slowFillLeaves.length < 2 ? 2 : slowFillLeaves.length;
        leafHashes = new bytes32[](numLeaves);
        for (uint256 i = 0; i < slowFillLeaves.length; i++) {
            leafHashes[i] = _hashSlowFillLeaf(slowFillLeaves[i]);
        }
        // Add dummy leaf if only one real leaf
        if (slowFillLeaves.length == 1) {
            leafHashes[1] = keccak256("dummy");
        }
        root = merkle.getRoot(leafHashes);
    }

    function _getProof(bytes32[] memory leafHashes, uint256 index) internal view returns (bytes32[] memory) {
        return merkle.getProof(leafHashes, index);
    }

    /*//////////////////////////////////////////////////////////////
                    REQUEST_SLOW_FILL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRequestSlowFillExpiredFillDeadline() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        relayData.fillDeadline = uint32(spokePool.getCurrentTime()) - 1;

        // Set time after exclusivity deadline
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.ExpiredFillDeadline.selector);
        spokePool.requestSlowFill(relayData);
    }

    function testRequestSlowFillInAbsenceOfExclusivity() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        // Clock drift between spokes can mean exclusivityDeadline is in future even when no exclusivity was applied.
        spokePool.setCurrentTime(relayData.exclusivityDeadline - 1);

        // Set exclusivityDeadline to 0 (no exclusivity)
        relayData.exclusivityDeadline = 0;

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit RequestedSlowFill(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayData.depositor,
            relayData.recipient,
            _hashNonEmptyMessage(relayData.message)
        );
        spokePool.requestSlowFill(relayData);
    }

    function testRequestSlowFillDuringExclusivityDeadline() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        // Set time to exclusivity deadline (still exclusive)
        spokePool.setCurrentTime(relayData.exclusivityDeadline);

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.NoSlowFillsInExclusivityWindow.selector);
        spokePool.requestSlowFill(relayData);
    }

    function testRequestSlowFillCanRequestBeforeFastFill() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        bytes32 relayHash = _getRelayHash(relayData, DESTINATION_CHAIN_ID);

        // Set time after exclusivity deadline
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        // FillStatus must be Unfilled
        assertEq(spokePool.fillStatuses(relayHash), FILL_STATUS_UNFILLED);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit RequestedSlowFill(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayData.depositor,
            relayData.recipient,
            _hashNonEmptyMessage(relayData.message)
        );
        spokePool.requestSlowFill(relayData);

        // FillStatus gets reset to RequestedSlowFill
        assertEq(spokePool.fillStatuses(relayHash), FILL_STATUS_REQUESTED_SLOW_FILL);

        // Can't request slow fill again
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.InvalidSlowFillRequest.selector);
        spokePool.requestSlowFill(relayData);

        // Can fast fill after
        vm.prank(relayer);
        spokePool.fillRelay(relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }

    function testRequestSlowFillCannotRequestIfFillStatusFilled() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        bytes32 relayHash = _getRelayHash(relayData, DESTINATION_CHAIN_ID);

        // Set time after exclusivity deadline
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        spokePool.setFillStatus(relayHash, V3SpokePoolInterface.FillType.SlowFill);
        assertEq(spokePool.fillStatuses(relayHash), FILL_STATUS_FILLED);

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.InvalidSlowFillRequest.selector);
        spokePool.requestSlowFill(relayData);
    }

    function testRequestSlowFillFillsArePaused() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        // Set time after exclusivity deadline
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        vm.prank(owner);
        spokePool.pauseFills(true);

        vm.prank(relayer);
        vm.expectRevert(SpokePoolInterface.FillsArePaused.selector);
        spokePool.requestSlowFill(relayData);
    }

    function testRequestSlowFillReentrancyProtected() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();

        // Set time after exclusivity deadline
        spokePool.setCurrentTime(relayData.exclusivityDeadline + 1);

        bytes memory functionCalldata = abi.encodeCall(spokePool.requestSlowFill, (relayData));

        vm.prank(depositor);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        spokePool.callback(functionCalldata);
    }

    /*//////////////////////////////////////////////////////////////
                EXECUTE_SLOW_RELAY_LEAF TESTS
    //////////////////////////////////////////////////////////////*/

    function testExecuteSlowRelayLeafHappyCase() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3SlowFill memory slowRelayLeaf = _buildSlowFillLeaf(relayData);

        V3SpokePoolInterface.V3SlowFill[] memory leaves = new V3SpokePoolInterface.V3SlowFill[](1);
        leaves[0] = slowRelayLeaf;

        (bytes32 root, bytes32[] memory leafHashes) = _buildSlowFillTree(leaves);

        vm.prank(owner);
        spokePool.relayRootBundle(MOCK_TREE_ROOT, root);

        bytes32[] memory proof = _getProof(leafHashes, 0);

        uint256 spokePoolBalanceBefore = destErc20.balanceOf(address(spokePool));
        uint256 recipientBalanceBefore = destErc20.balanceOf(recipient);

        vm.prank(recipient);
        spokePool.executeSlowRelayLeaf(slowRelayLeaf, 0, proof);

        assertEq(destErc20.balanceOf(address(spokePool)), spokePoolBalanceBefore - slowRelayLeaf.updatedOutputAmount);
        assertEq(destErc20.balanceOf(recipient), recipientBalanceBefore + slowRelayLeaf.updatedOutputAmount);
    }

    function testExecuteSlowRelayLeafCannotDoubleExecute() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3SlowFill memory slowRelayLeaf = _buildSlowFillLeaf(relayData);

        V3SpokePoolInterface.V3SlowFill[] memory leaves = new V3SpokePoolInterface.V3SlowFill[](1);
        leaves[0] = slowRelayLeaf;

        (bytes32 root, bytes32[] memory leafHashes) = _buildSlowFillTree(leaves);

        vm.prank(owner);
        spokePool.relayRootBundle(MOCK_TREE_ROOT, root);

        bytes32[] memory proof = _getProof(leafHashes, 0);

        vm.prank(relayer);
        spokePool.executeSlowRelayLeaf(slowRelayLeaf, 0, proof);

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.executeSlowRelayLeaf(slowRelayLeaf, 0, proof);

        // Cannot fast fill after slow fill
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.fillRelay(slowRelayLeaf.relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }

    function testExecuteSlowRelayLeafCannotDoubleSendFill() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3SlowFill memory slowRelayLeaf = _buildSlowFillLeaf(relayData);

        V3SpokePoolInterface.V3SlowFill[] memory leaves = new V3SpokePoolInterface.V3SlowFill[](1);
        leaves[0] = slowRelayLeaf;

        (bytes32 root, bytes32[] memory leafHashes) = _buildSlowFillTree(leaves);

        vm.prank(owner);
        spokePool.relayRootBundle(MOCK_TREE_ROOT, root);

        // Fill before executing slow fill
        vm.prank(relayer);
        spokePool.fillRelay(slowRelayLeaf.relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32());

        bytes32[] memory proof = _getProof(leafHashes, 0);

        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.executeSlowRelayLeaf(slowRelayLeaf, 0, proof);
    }

    function testExecuteSlowRelayLeafCannotReenter() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3SlowFill memory slowRelayLeaf = _buildSlowFillLeaf(relayData);

        V3SpokePoolInterface.V3SlowFill[] memory leaves = new V3SpokePoolInterface.V3SlowFill[](1);
        leaves[0] = slowRelayLeaf;

        (, bytes32[] memory leafHashes) = _buildSlowFillTree(leaves);

        bytes32[] memory proof = _getProof(leafHashes, 0);

        bytes memory functionCalldata = abi.encodeCall(spokePool.executeSlowRelayLeaf, (slowRelayLeaf, 0, proof));

        vm.prank(depositor);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        spokePool.callback(functionCalldata);
    }

    function testExecuteSlowRelayLeafCanExecuteEvenIfFillsPaused() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3SlowFill memory slowRelayLeaf = _buildSlowFillLeaf(relayData);

        V3SpokePoolInterface.V3SlowFill[] memory leaves = new V3SpokePoolInterface.V3SlowFill[](1);
        leaves[0] = slowRelayLeaf;

        (bytes32 root, bytes32[] memory leafHashes) = _buildSlowFillTree(leaves);

        vm.prank(owner);
        spokePool.relayRootBundle(MOCK_TREE_ROOT, root);

        vm.prank(owner);
        spokePool.pauseFills(true);

        bytes32[] memory proof = _getProof(leafHashes, 0);

        // Should not revert even though fills are paused
        vm.prank(relayer);
        spokePool.executeSlowRelayLeaf(slowRelayLeaf, 0, proof);
    }

    function testExecuteSlowRelayLeafExecutesPreLeafExecuteHook() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3SlowFill memory slowRelayLeaf = _buildSlowFillLeaf(relayData);

        V3SpokePoolInterface.V3SlowFill[] memory leaves = new V3SpokePoolInterface.V3SlowFill[](1);
        leaves[0] = slowRelayLeaf;

        (bytes32 root, bytes32[] memory leafHashes) = _buildSlowFillTree(leaves);

        vm.prank(owner);
        spokePool.relayRootBundle(MOCK_TREE_ROOT, root);

        bytes32[] memory proof = _getProof(leafHashes, 0);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit PreLeafExecuteHook(slowRelayLeaf.relayData.outputToken);
        spokePool.executeSlowRelayLeaf(slowRelayLeaf, 0, proof);
    }

    function testExecuteSlowRelayLeafCannotExecuteWithWrongChainId() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3SlowFill memory slowRelayLeafWithWrongChain = V3SpokePoolInterface.V3SlowFill({
            relayData: relayData,
            chainId: DESTINATION_CHAIN_ID + 1, // Wrong chain ID
            updatedOutputAmount: relayData.outputAmount + 1
        });

        V3SpokePoolInterface.V3SlowFill[] memory leaves = new V3SpokePoolInterface.V3SlowFill[](1);
        leaves[0] = slowRelayLeafWithWrongChain;

        (bytes32 root, bytes32[] memory leafHashes) = _buildSlowFillTree(leaves);

        vm.prank(owner);
        spokePool.relayRootBundle(MOCK_TREE_ROOT, root);

        bytes32[] memory proof = _getProof(leafHashes, 0);

        // Root is valid and leaf is contained in tree, but chain ID doesn't match pool's chain ID
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.InvalidMerkleProof.selector);
        spokePool.executeSlowRelayLeaf(slowRelayLeafWithWrongChain, 0, proof);
    }

    function testVerifyV3SlowFill() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3SlowFill memory slowRelayLeaf = _buildSlowFillLeaf(relayData);
        V3SpokePoolInterface.V3SlowFill memory leafWithDifferentUpdatedOutputAmount = V3SpokePoolInterface.V3SlowFill({
            relayData: relayData,
            chainId: DESTINATION_CHAIN_ID,
            updatedOutputAmount: slowRelayLeaf.updatedOutputAmount + 1
        });

        V3SpokePoolInterface.V3SlowFill[] memory leaves = new V3SpokePoolInterface.V3SlowFill[](2);
        leaves[0] = slowRelayLeaf;
        leaves[1] = leafWithDifferentUpdatedOutputAmount;

        (bytes32 root, bytes32[] memory leafHashes) = _buildSlowFillTree(leaves);

        vm.prank(owner);
        spokePool.relayRootBundle(MOCK_TREE_ROOT, root);

        vm.prank(owner);
        spokePool.relayRootBundle(MOCK_TREE_ROOT, MOCK_TREE_ROOT);

        // Incorrect root bundle ID
        bytes32[] memory proof = _getProof(leafHashes, 0);
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.InvalidMerkleProof.selector);
        spokePool.executeSlowRelayLeaf(slowRelayLeaf, 1, proof); // rootBundleId should be 0

        // Invalid proof
        bytes32[] memory wrongProof = _getProof(leafHashes, 1); // Proof for different leaf
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.InvalidMerkleProof.selector);
        spokePool.executeSlowRelayLeaf(slowRelayLeaf, 0, wrongProof);

        // Incorrect relay execution params, not matching leaf used to construct proof
        bytes32[] memory correctProof = _getProof(leafHashes, 0);
        vm.prank(relayer);
        vm.expectRevert(V3SpokePoolInterface.InvalidMerkleProof.selector);
        spokePool.executeSlowRelayLeaf(leafWithDifferentUpdatedOutputAmount, 0, correctProof);
    }

    function testExecuteSlowRelayLeafCallsFillRelayWithExpectedParams() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _createRelayData();
        V3SpokePoolInterface.V3SlowFill memory slowRelayLeaf = _buildSlowFillLeaf(relayData);

        V3SpokePoolInterface.V3SlowFill[] memory leaves = new V3SpokePoolInterface.V3SlowFill[](1);
        leaves[0] = slowRelayLeaf;

        (bytes32 root, bytes32[] memory leafHashes) = _buildSlowFillTree(leaves);

        vm.prank(owner);
        spokePool.relayRootBundle(MOCK_TREE_ROOT, root);

        bytes32[] memory proof = _getProof(leafHashes, 0);

        // Record logs to verify event parameters
        vm.recordLogs();
        vm.prank(relayer);
        spokePool.executeSlowRelayLeaf(slowRelayLeaf, 0, proof);

        // Check that FilledRelay was emitted with correct parameters
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 filledRelaySelector = keccak256(
            "FilledRelay(bytes32,bytes32,uint256,uint256,uint256,uint256,uint256,uint32,uint32,bytes32,bytes32,bytes32,bytes32,bytes32,(bytes32,bytes32,uint256,uint8))"
        );

        bool foundFilledRelay = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == filledRelaySelector) {
                foundFilledRelay = true;
                // Verify indexed parameters
                assertEq(entries[i].topics[1], bytes32(relayData.originChainId)); // originChainId
                assertEq(entries[i].topics[2], bytes32(relayData.depositId)); // depositId
                assertEq(entries[i].topics[3], address(0).toBytes32()); // relayer set to 0x0 for slow fill
                break;
            }
        }
        assertTrue(foundFilledRelay, "FilledRelay event not found");

        // Sanity check that executed slow fill leaf's updatedOutputAmount is different than the relayData.outputAmount
        assertTrue(slowRelayLeaf.relayData.outputAmount != slowRelayLeaf.updatedOutputAmount);
    }
}
