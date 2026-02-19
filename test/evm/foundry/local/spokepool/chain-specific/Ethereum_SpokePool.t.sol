// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Contracts under test
import { Ethereum_SpokePool } from "../../../../../../contracts/Ethereum_SpokePool.sol";
import { SpokePoolInterface } from "../../../../../../contracts/interfaces/SpokePoolInterface.sol";

// Mocks
import { MintableERC20 } from "../../../../../../contracts/test/MockERC20.sol";
import { WETH9 } from "../../../../../../contracts/external/WETH9.sol";

// Utils
import { MerkleTreeUtils } from "../../../utils/MerkleTreeUtils.sol";

/**
 * @title Ethereum_SpokePoolTest
 * @notice Foundry tests for Ethereum_SpokePool, ported from Hardhat tests.
 * @dev Tests admin functions and token bridging (which is a simple transfer on L1).
 */
contract Ethereum_SpokePoolTest is Test {
    // ============ Test Constants ============

    uint256 constant AMOUNT_TO_RETURN = 1 ether;
    uint256 constant AMOUNT_HELD_BY_POOL = 100 ether;
    uint32 constant TEST_DEPOSIT_QUOTE_TIME_BUFFER = 1 hours;
    uint32 constant TEST_FILL_DEADLINE_BUFFER = 9 hours;

    // ============ Contracts ============

    Ethereum_SpokePool public spokePool;
    Ethereum_SpokePool public spokePoolImplementation;

    // ============ Mocks ============

    WETH9 public weth;
    MintableERC20 public dai;

    // ============ Addresses ============

    address public owner;
    address public relayer;
    address public rando;
    address public hubPool;

    // ============ Test State ============

    bytes32 public mockTreeRoot;

    // ============ Setup ============

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");
        hubPool = makeAddr("hubPool");

        // Deploy tokens
        weth = new WETH9();
        dai = new MintableERC20("DAI", "DAI", 18);

        // Deploy Ethereum SpokePool implementation
        spokePoolImplementation = new Ethereum_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );

        // Deploy proxy with owner as deployer
        vm.prank(owner);
        bytes memory initData = abi.encodeCall(Ethereum_SpokePool.initialize, (0, hubPool));
        ERC1967Proxy proxy = new ERC1967Proxy(address(spokePoolImplementation), initData);
        spokePool = Ethereum_SpokePool(payable(address(proxy)));

        // Seed SpokePool with tokens
        dai.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
        vm.deal(address(spokePool), 10 ether);

        // Setup mock tree root
        mockTreeRoot = keccak256("mockTreeRoot");
    }

    // ============ Upgrade Tests ============

    function test_onlyOwnerCanUpgrade() public {
        // Deploy new implementation
        Ethereum_SpokePool newImplementation = new Ethereum_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );

        // Attempt upgrade from non-owner should fail
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.upgradeTo(address(newImplementation));

        // Upgrade from owner should succeed
        vm.prank(owner);
        spokePool.upgradeTo(address(newImplementation));
    }

    // ============ Admin Function Tests ============

    function test_onlyOwnerCanSetCrossDomainAdmin() public {
        // Attempt from non-owner should fail
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.setCrossDomainAdmin(rando);

        // Should succeed from owner
        vm.prank(owner);
        spokePool.setCrossDomainAdmin(rando);

        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function test_onlyOwnerCanSetWithdrawalRecipient() public {
        // Attempt from non-owner should fail
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.setWithdrawalRecipient(rando);

        // Should succeed from owner
        vm.prank(owner);
        spokePool.setWithdrawalRecipient(rando);

        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function test_onlyOwnerCanRelayRootBundle() public {
        // Attempt from non-owner should fail
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Should succeed from owner
        vm.prank(owner);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function test_onlyOwnerCanDeleteRootBundle() public {
        // First, relay a root bundle
        vm.prank(owner);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Attempt to delete from non-owner should fail
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.emergencyDeleteRootBundle(0);

        // Should succeed from owner
        vm.prank(owner);
        spokePool.emergencyDeleteRootBundle(0);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    // ============ Bridge Tokens Tests ============

    function test_bridgeTokensToHubPoolCorrectlySendsTokens() public {
        // Build relayer refund leaf and root
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(dai), AMOUNT_TO_RETURN);

        // Relay root bundle
        vm.prank(owner);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Record balances before
        uint256 spokePoolBalanceBefore = dai.balanceOf(address(spokePool));
        uint256 hubPoolBalanceBefore = dai.balanceOf(hubPool);

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify token balances changed correctly
        assertEq(dai.balanceOf(address(spokePool)), spokePoolBalanceBefore - AMOUNT_TO_RETURN);
        assertEq(dai.balanceOf(hubPool), hubPoolBalanceBefore + AMOUNT_TO_RETURN);
    }
}
