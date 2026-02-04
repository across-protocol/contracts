// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

// Contracts under test
import { Linea_SpokePool } from "../../../../../../contracts/Linea_SpokePool.sol";
import { SpokePoolInterface } from "../../../../../../contracts/interfaces/SpokePoolInterface.sol";
import { IMessageService, ITokenBridge } from "../../../../../../contracts/external/interfaces/LineaInterfaces.sol";

// Mocks
import { MockL2MessageService, MockL2TokenBridge } from "../../../../../../contracts/test/LineaMocks.sol";
import { MockCCTPMessenger, MockCCTPMinter } from "../../../../../../contracts/test/MockCCTP.sol";
import { MintableERC20 } from "../../../../../../contracts/test/MockERC20.sol";
import { WETH9 } from "../../../../../../contracts/external/WETH9.sol";

// Utils
import { MerkleTreeUtils } from "../../../utils/MerkleTreeUtils.sol";

/**
 * @title Linea_SpokePoolTest
 * @notice Foundry tests for Linea_SpokePool, ported from Hardhat tests.
 * @dev Tests admin functions, token bridging via Token Bridge, and ETH bridging via Message Service.
 */
contract Linea_SpokePoolTest is Test {
    // ============ Test Constants ============

    uint256 constant AMOUNT_TO_RETURN = 1 ether;
    uint256 constant AMOUNT_HELD_BY_POOL = 100 ether;
    uint32 constant TEST_DEPOSIT_QUOTE_TIME_BUFFER = 1 hours;
    uint32 constant TEST_FILL_DEADLINE_BUFFER = 9 hours;

    // ============ Contracts ============

    Linea_SpokePool public spokePool;
    Linea_SpokePool public spokePoolImplementation;

    // ============ Mocks ============

    WETH9 public weth;
    MintableERC20 public dai;
    MintableERC20 public usdc;
    MockL2MessageService public l2MessageService;
    MockL2TokenBridge public l2TokenBridge;
    MockCCTPMessenger public cctpMessenger;
    MockCCTPMinter public cctpMinter;

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
        usdc = new MintableERC20("USDC", "USDC", 6);

        // Deploy Linea mocks
        l2MessageService = new MockL2MessageService();
        l2TokenBridge = new MockL2TokenBridge();

        // Deploy CCTP mocks
        cctpMinter = new MockCCTPMinter();
        cctpMessenger = new MockCCTPMessenger(cctpMinter);
        cctpMinter.setBurnLimit(1_000_000e6); // 1M USDC limit

        // Fund the message service with ETH (needed for impersonation)
        vm.deal(address(l2MessageService), 10 ether);

        // Deploy Linea SpokePool implementation
        spokePoolImplementation = new Linea_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER,
            IERC20(address(usdc)),
            cctpMessenger
        );

        // Deploy proxy
        bytes memory initData = abi.encodeCall(
            Linea_SpokePool.initialize,
            (0, IMessageService(address(l2MessageService)), ITokenBridge(address(l2TokenBridge)), owner, hubPool)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(spokePoolImplementation), initData);
        spokePool = Linea_SpokePool(payable(address(proxy)));

        // Seed SpokePool with tokens and ETH/WETH
        dai.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
        usdc.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
        // Give enough ETH to convert to WETH plus extra for operations
        vm.deal(address(spokePool), AMOUNT_HELD_BY_POOL + 10 ether);
        // Convert some ETH to WETH for SpokePool
        vm.prank(address(spokePool));
        weth.deposit{ value: AMOUNT_HELD_BY_POOL }();

        // Fund relayer with ETH for fee payments
        vm.deal(relayer, 10 ether);

        // Setup mock tree root
        mockTreeRoot = keccak256("mockTreeRoot");
    }

    // ============ Helper Functions ============

    /**
     * @notice Helper to simulate cross-domain admin call.
     * @dev Sets the sender in message service and pranks from message service address.
     */
    function _asCrossDomainAdmin() internal {
        l2MessageService.setSender(owner);
        vm.prank(address(l2MessageService));
    }

    // ============ Upgrade Tests ============

    function test_onlyCrossDomainOwnerCanUpgrade() public {
        // Deploy new implementation
        Linea_SpokePool newImplementation = new Linea_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER,
            IERC20(address(usdc)),
            cctpMessenger
        );

        // Attempt upgrade from non-cross-domain admin should fail
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.upgradeTo(address(newImplementation));

        // Setting sender but calling from wrong address should also fail
        l2MessageService.setSender(owner);
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        vm.prank(owner);
        spokePool.upgradeTo(address(newImplementation));

        // Upgrade from cross domain admin should succeed
        _asCrossDomainAdmin();
        spokePool.upgradeTo(address(newImplementation));
    }

    // ============ Admin Function Tests ============

    function test_onlyCrossDomainOwnerCanSetL2MessageService() public {
        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.setL2MessageService(IMessageService(rando));

        // Should succeed from cross domain admin
        _asCrossDomainAdmin();
        spokePool.setL2MessageService(IMessageService(rando));

        assertEq(address(spokePool.l2MessageService()), rando);
    }

    function test_onlyCrossDomainOwnerCanSetL2TokenBridge() public {
        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.setL2TokenBridge(ITokenBridge(rando));

        // Should succeed from cross domain admin
        _asCrossDomainAdmin();
        spokePool.setL2TokenBridge(ITokenBridge(rando));

        assertEq(address(spokePool.l2TokenBridge()), rando);
    }

    function test_onlyCrossDomainOwnerCanRelayRootBundle() public {
        // Build a merkle tree
        (, bytes32 root) = MerkleTreeUtils.buildRelayerRefundLeafAndRoot(
            spokePool.chainId(),
            address(dai),
            AMOUNT_TO_RETURN
        );

        // Attempt from non-admin should fail
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Should succeed from cross domain admin
        _asCrossDomainAdmin();
        spokePool.relayRootBundle(root, mockTreeRoot);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, root);
    }

    // ============ Message Fee Tests ============

    function test_antiDDoSMessageFeeNeedsToBeSet() public {
        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(dai), AMOUNT_TO_RETURN);

        // Relay root bundle
        _asCrossDomainAdmin();
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Set a non-zero minimum fee
        l2MessageService.setMinimumFeeInWei(1);

        // Execute without fee should fail
        vm.expectRevert("MESSAGE_FEE_MISMATCH");
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }

    // ============ Bridge Tokens via Token Bridge Tests ============

    function test_bridgeTokensToHubPoolCallsL2TokenBridgeForERC20() public {
        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(dai), AMOUNT_TO_RETURN);

        // Relay root bundle
        _asCrossDomainAdmin();
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Set a positive fee to test fee handling
        uint256 fee = 0.01 ether;
        l2MessageService.setMinimumFeeInWei(fee);

        // Execute leaf with fee
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf{ value: fee }(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify token bridge was called correctly
        assertEq(l2TokenBridge.bridgeTokenCallCount(), 1);
        (address token, uint256 amount, address recipient, uint256 value) = l2TokenBridge.lastBridgeTokenCall();
        assertEq(token, address(dai));
        assertEq(amount, AMOUNT_TO_RETURN);
        assertEq(recipient, hubPool);
        assertEq(value, fee);
    }

    // ============ Bridge ETH via Message Service Tests ============

    function test_bridgeETHToHubPoolCallsMessageServiceForWETH() public {
        // Build relayer refund leaf for WETH
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(weth), AMOUNT_TO_RETURN);

        // Relay root bundle
        _asCrossDomainAdmin();
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Set a positive fee
        uint256 fee = 0.01 ether;
        l2MessageService.setMinimumFeeInWei(fee);

        // Execute leaf with fee
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf{ value: fee }(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify message service was called correctly
        // Note: Linea SpokePool wraps all ETH to WETH in _preExecuteLeafHook, then unwraps for bridging
        assertEq(l2MessageService.sendMessageCallCount(), 1);
        (address to, uint256 msgFee, , uint256 value) = l2MessageService.lastSendMessageCall();
        assertEq(to, hubPool);
        assertEq(msgFee, fee);
        assertEq(value, AMOUNT_TO_RETURN + fee);
    }
}
