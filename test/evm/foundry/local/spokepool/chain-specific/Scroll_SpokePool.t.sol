// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Contracts under test
import { Scroll_SpokePool } from "../../../../../../contracts/Scroll_SpokePool.sol";
import { SpokePool } from "../../../../../../contracts/SpokePool.sol";
import { SpokePoolInterface } from "../../../../../../contracts/interfaces/SpokePoolInterface.sol";

// Mocks
import { MockScrollMessenger, MockScrollL2GatewayRouter } from "../../../../../../contracts/test/ScrollMocks.sol";
import { MintableERC20 } from "../../../../../../contracts/test/MockERC20.sol";
import { WETH9 } from "../../../../../../contracts/external/WETH9.sol";

// Utils
import { MerkleTreeUtils } from "../../../utils/MerkleTreeUtils.sol";

// Scroll interfaces
import { IL2GatewayRouterExtended } from "../../../../../../contracts/Scroll_SpokePool.sol";
import { IScrollMessenger } from "@scroll-tech/contracts/libraries/IScrollMessenger.sol";

/**
 * @title Scroll_SpokePoolTest
 * @notice Foundry tests for Scroll_SpokePool, ported from Hardhat tests.
 * @dev Tests admin functions, token bridging via L2GatewayRouter, and cross-domain messaging.
 *
 * Hardhat source: test/evm/hardhat/chain-specific-spokepools/Scroll_SpokePool.ts
 * Tests migrated:
 *   1. Only cross domain owner can upgrade logic contract
 *   2. Only cross domain owner can set the new L2GatewayRouter
 *   3. Only cross domain owner can set the new L2Messenger
 *   4. Only cross domain owner can relay admin root bundles
 *   5. Bridge tokens to hub pool correctly calls the L2GatewayRouter for ERC20
 */
contract Scroll_SpokePoolTest is Test {
    // ============ Test Constants ============

    uint256 constant AMOUNT_TO_RETURN = 1 ether;
    uint256 constant AMOUNT_HELD_BY_POOL = 100 ether;
    uint32 constant TEST_DEPOSIT_QUOTE_TIME_BUFFER = 1 hours;
    uint32 constant TEST_FILL_DEADLINE_BUFFER = 2 hours;

    string constant NO_ADMIN_REVERT = "Sender must be admin";

    // ============ Contracts ============

    Scroll_SpokePool public spokePool;
    Scroll_SpokePool public spokePoolImplementation;

    // ============ Mocks ============

    WETH9 public weth;
    MintableERC20 public dai;
    MockScrollMessenger public l2Messenger;
    MockScrollL2GatewayRouter public l2GatewayRouter;

    // ============ Addresses ============

    address public owner;
    address public relayer;
    address public rando;
    address public hubPool;

    // ============ Test State ============

    bytes32 public mockTreeRoot;

    // ============ Events ============

    event WithdrawERC20Called(address indexed token, address indexed to, uint256 amount, uint256 gasLimit);

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

        // Deploy mocks
        l2Messenger = new MockScrollMessenger();
        l2GatewayRouter = new MockScrollL2GatewayRouter();

        // Deploy Scroll SpokePool implementation
        spokePoolImplementation = new Scroll_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );

        // Deploy proxy
        bytes memory initData = abi.encodeCall(
            Scroll_SpokePool.initialize,
            (
                IL2GatewayRouterExtended(address(l2GatewayRouter)),
                IScrollMessenger(address(l2Messenger)),
                0,
                owner,
                hubPool
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(spokePoolImplementation), initData);
        spokePool = Scroll_SpokePool(payable(address(proxy)));

        // Seed SpokePool with tokens
        dai.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
        vm.deal(address(spokePool), AMOUNT_HELD_BY_POOL);
        vm.prank(address(spokePool));
        weth.deposit{ value: AMOUNT_HELD_BY_POOL }();

        // Setup mock tree root
        mockTreeRoot = keccak256("mockTreeRoot");
    }

    // ============ Helper Functions ============

    /**
     * @notice Executes a function call as the cross-domain admin via the messenger
     */
    function _callAsCrossDomainAdmin(bytes memory data) internal {
        vm.prank(owner);
        l2Messenger.impersonateCall(address(spokePool), data);
    }

    // ============ Upgrade Tests ============

    function test_onlyCrossDomainOwnerCanUpgrade() public {
        // Deploy new implementation
        Scroll_SpokePool newImplementation = new Scroll_SpokePool(address(weth), 60 * 60, 9 * 60 * 60);

        // Attempt upgrade from random address should fail
        vm.prank(rando);
        vm.expectRevert(bytes(NO_ADMIN_REVERT));
        spokePool.upgradeTo(address(newImplementation));

        // Upgrade from cross domain admin (owner) should succeed
        _callAsCrossDomainAdmin(abi.encodeCall(spokePool.upgradeTo, (address(newImplementation))));
    }

    // ============ Admin Function Tests ============

    function test_onlyCrossDomainOwnerCanSetL2GatewayRouter() public {
        address newL2GatewayRouter = makeAddr("newL2GatewayRouter");

        // Attempt from non-admin should fail
        vm.prank(rando);
        vm.expectRevert(bytes(NO_ADMIN_REVERT));
        spokePool.setL2GatewayRouter(IL2GatewayRouterExtended(rando));

        // Should succeed from cross domain admin
        _callAsCrossDomainAdmin(
            abi.encodeCall(spokePool.setL2GatewayRouter, (IL2GatewayRouterExtended(newL2GatewayRouter)))
        );

        assertEq(address(spokePool.l2GatewayRouter()), newL2GatewayRouter);
    }

    function test_onlyCrossDomainOwnerCanSetL2ScrollMessenger() public {
        address newL2Messenger = makeAddr("newL2Messenger");

        // Attempt from non-admin should fail
        vm.prank(rando);
        vm.expectRevert(bytes(NO_ADMIN_REVERT));
        spokePool.setL2ScrollMessenger(IScrollMessenger(rando));

        // Should succeed from cross domain admin
        _callAsCrossDomainAdmin(abi.encodeCall(spokePool.setL2ScrollMessenger, (IScrollMessenger(newL2Messenger))));

        assertEq(address(spokePool.l2ScrollMessenger()), newL2Messenger);
    }

    function test_onlyCrossDomainOwnerCanRelayRootBundle() public {
        // Build relayer refund leaf
        (, bytes32 relayerRefundRoot) = MerkleTreeUtils.buildRelayerRefundLeafAndRoot(
            spokePool.chainId(),
            address(dai),
            AMOUNT_TO_RETURN
        );

        // Attempt from non-admin should fail
        vm.expectRevert(bytes(NO_ADMIN_REVERT));
        spokePool.relayRootBundle(relayerRefundRoot, mockTreeRoot);

        // Should succeed from cross domain admin
        // relayRootBundle(relayerRefundRoot, slowRelayRoot)
        _callAsCrossDomainAdmin(abi.encodeCall(spokePool.relayRootBundle, (relayerRefundRoot, mockTreeRoot)));

        // rootBundles returns (slowRelayRoot, relayerRefundRoot)
        (bytes32 storedSlowRelayRoot, bytes32 storedRelayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(storedSlowRelayRoot, mockTreeRoot);
        assertEq(storedRelayerRefundRoot, relayerRefundRoot);
    }

    // ============ Bridge Tokens Tests ============

    function test_bridgeTokensToHubPoolCallsL2GatewayRouterForERC20() public {
        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(dai), AMOUNT_TO_RETURN);

        // Relay root bundle
        _callAsCrossDomainAdmin(abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot)));

        // Expect WithdrawERC20Called event from mock gateway router
        vm.expectEmit(true, true, false, true, address(l2GatewayRouter));
        emit WithdrawERC20Called(address(dai), hubPool, AMOUNT_TO_RETURN, 0);

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify the gateway router was called with correct parameters
        assertEq(l2GatewayRouter.lastWithdrawToken(), address(dai));
        assertEq(l2GatewayRouter.lastWithdrawTo(), hubPool);
        assertEq(l2GatewayRouter.lastWithdrawAmount(), AMOUNT_TO_RETURN);
        assertEq(l2GatewayRouter.lastWithdrawGasLimit(), 0);
    }
}
