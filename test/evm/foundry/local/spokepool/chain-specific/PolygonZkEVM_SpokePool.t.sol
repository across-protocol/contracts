// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Contracts under test
import { PolygonZkEVM_SpokePool } from "../../../../../../contracts/PolygonZkEVM_SpokePool.sol";
import { SpokePoolInterface } from "../../../../../../contracts/interfaces/SpokePoolInterface.sol";
import { IPolygonZkEVMBridge } from "../../../../../../contracts/external/interfaces/IPolygonZkEVMBridge.sol";

// Mocks
import { MockPolygonZkEVMBridge } from "../../../../../../contracts/test/PolygonZkEVMMocks.sol";
import { MintableERC20 } from "../../../../../../contracts/test/MockERC20.sol";
import { WETH9 } from "../../../../../../contracts/external/WETH9.sol";

// Utils
import { MerkleTreeUtils } from "../../../utils/MerkleTreeUtils.sol";

/**
 * @title PolygonZkEVM_SpokePoolTest
 * @notice Foundry tests for PolygonZkEVM_SpokePool, ported from Hardhat tests.
 * @dev Tests admin functions, upgrade authorization, and token bridging via PolygonZkEVM Bridge.
 *
 * Hardhat source: test/evm/hardhat/chain-specific-spokepools/PolygonZkEVM_SpokePool.ts
 * Tests migrated:
 *   1. Only cross domain owner upgrade logic contract
 *   2. Only cross domain owner can set l2PolygonZkEVMBridge
 *   3. Bridge tokens to hub pool correctly calls the L2 Token Bridge for ETH
 *   4. Bridge tokens to hub pool correctly calls the L2 Token Bridge for ERC20
 */
contract PolygonZkEVM_SpokePoolTest is Test {
    // ============ Test Constants ============

    uint256 constant AMOUNT_TO_RETURN = 1 ether;
    uint256 constant AMOUNT_HELD_BY_POOL = 100 ether;
    uint32 constant TEST_DEPOSIT_QUOTE_TIME_BUFFER = 1 hours;
    uint32 constant TEST_FILL_DEADLINE_BUFFER = 9 hours;
    uint32 constant POLYGON_ZKEVM_L1_NETWORK_ID = 0;

    // ============ Contracts ============

    PolygonZkEVM_SpokePool public spokePool;
    PolygonZkEVM_SpokePool public spokePoolImplementation;

    // ============ Mocks ============

    WETH9 public weth;
    MintableERC20 public dai;
    MockPolygonZkEVMBridge public polygonZkEvmBridge;

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

        // Deploy PolygonZkEVM bridge mock
        polygonZkEvmBridge = new MockPolygonZkEVMBridge();

        // Fund the bridge mock with ETH (needed for impersonation)
        vm.deal(address(polygonZkEvmBridge), 10 ether);

        // Deploy PolygonZkEVM SpokePool implementation
        spokePoolImplementation = new PolygonZkEVM_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );

        // Deploy proxy
        bytes memory initData = abi.encodeCall(
            PolygonZkEVM_SpokePool.initialize,
            (IPolygonZkEVMBridge(address(polygonZkEvmBridge)), 0, owner, hubPool)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(spokePoolImplementation), initData);
        spokePool = PolygonZkEVM_SpokePool(payable(address(proxy)));

        // Seed SpokePool with tokens and ETH/WETH
        dai.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
        // Give enough ETH to convert to WETH plus extra for operations
        vm.deal(address(spokePool), AMOUNT_HELD_BY_POOL + 10 ether);
        // Convert some ETH to WETH for SpokePool
        vm.prank(address(spokePool));
        weth.deposit{ value: AMOUNT_HELD_BY_POOL }();

        // Fund relayer with ETH
        vm.deal(relayer, 10 ether);

        // Setup mock tree root
        mockTreeRoot = keccak256("mockTreeRoot");
    }

    // ============ Helper Functions ============

    /**
     * @notice Helper to simulate cross-domain admin call via onMessageReceived.
     * @param data The encoded function call data to execute.
     */
    function _callAsCrossDomainAdmin(bytes memory data) internal {
        vm.prank(address(polygonZkEvmBridge));
        spokePool.onMessageReceived(owner, POLYGON_ZKEVM_L1_NETWORK_ID, data);
    }

    // ============ Upgrade Tests ============

    function test_onlyCrossDomainOwnerCanUpgrade() public {
        // Deploy new implementation
        PolygonZkEVM_SpokePool newImplementation = new PolygonZkEVM_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );

        bytes memory upgradeData = abi.encodeWithSelector(spokePool.upgradeTo.selector, address(newImplementation));

        // Reverts if called directly (not via onMessageReceived)
        vm.expectRevert(PolygonZkEVM_SpokePool.AdminCallNotValidated.selector);
        spokePool.upgradeTo(address(newImplementation));

        // Reverts if called not from bridge
        vm.expectRevert(PolygonZkEVM_SpokePool.CallerNotBridge.selector);
        vm.prank(rando);
        spokePool.onMessageReceived(owner, POLYGON_ZKEVM_L1_NETWORK_ID, upgradeData);

        // Reverts if called by non-admin (origin sender is not crossDomainAdmin)
        vm.expectRevert(PolygonZkEVM_SpokePool.OriginSenderNotCrossDomain.selector);
        vm.prank(address(polygonZkEvmBridge));
        spokePool.onMessageReceived(rando, POLYGON_ZKEVM_L1_NETWORK_ID, upgradeData);

        // Reverts if source network is not L1
        vm.expectRevert(PolygonZkEVM_SpokePool.SourceChainNotHubChain.selector);
        vm.prank(address(polygonZkEvmBridge));
        spokePool.onMessageReceived(owner, 1, upgradeData);

        // Should succeed when called correctly via cross-domain admin
        _callAsCrossDomainAdmin(upgradeData);
    }

    // ============ Admin Function Tests ============

    function test_onlyCrossDomainOwnerCanSetL2PolygonZkEVMBridge() public {
        bytes memory setL2BridgeData = abi.encodeWithSelector(spokePool.setL2PolygonZkEVMBridge.selector, rando);

        // Reverts if called directly (not via onMessageReceived)
        vm.expectRevert(PolygonZkEVM_SpokePool.AdminCallNotValidated.selector);
        spokePool.setL2PolygonZkEVMBridge(IPolygonZkEVMBridge(rando));

        // Reverts if called not from bridge
        vm.expectRevert(PolygonZkEVM_SpokePool.CallerNotBridge.selector);
        vm.prank(rando);
        spokePool.onMessageReceived(owner, POLYGON_ZKEVM_L1_NETWORK_ID, setL2BridgeData);

        // Reverts if called by non-admin (origin sender is not crossDomainAdmin)
        vm.expectRevert(PolygonZkEVM_SpokePool.OriginSenderNotCrossDomain.selector);
        vm.prank(address(polygonZkEvmBridge));
        spokePool.onMessageReceived(rando, POLYGON_ZKEVM_L1_NETWORK_ID, setL2BridgeData);

        // Reverts if source network is not L1
        vm.expectRevert(PolygonZkEVM_SpokePool.SourceChainNotHubChain.selector);
        vm.prank(address(polygonZkEvmBridge));
        spokePool.onMessageReceived(owner, 1, setL2BridgeData);

        // Should succeed when called correctly via cross-domain admin
        _callAsCrossDomainAdmin(setL2BridgeData);

        assertEq(address(spokePool.l2PolygonZkEVMBridge()), rando);
    }

    // ============ Bridge Tokens Tests ============

    function test_bridgeTokensToHubPoolCallsL2TokenBridgeForETH() public {
        // Build relayer refund leaf for WETH
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(weth), AMOUNT_TO_RETURN);

        // Relay root bundle via cross-domain admin
        bytes memory relayRootBundleData = abi.encodeWithSelector(
            spokePool.relayRootBundle.selector,
            root,
            mockTreeRoot
        );
        _callAsCrossDomainAdmin(relayRootBundleData);

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify bridge was called correctly for ETH (token=address(0))
        assertEq(polygonZkEvmBridge.bridgeAssetCallCount(), 1);
        (
            uint32 destinationNetwork,
            address destinationAddress,
            uint256 amount,
            address token,
            bool forceUpdateGlobalExitRoot,
            bytes memory permitData,
            uint256 value
        ) = polygonZkEvmBridge.lastBridgeAssetCall();

        assertEq(destinationNetwork, POLYGON_ZKEVM_L1_NETWORK_ID);
        assertEq(destinationAddress, hubPool);
        assertEq(amount, AMOUNT_TO_RETURN);
        assertEq(token, address(0)); // ETH is bridged with token=0
        assertEq(forceUpdateGlobalExitRoot, true);
        assertEq(permitData, "");
        assertEq(value, AMOUNT_TO_RETURN); // ETH sent as msg.value
    }

    function test_bridgeTokensToHubPoolCallsL2TokenBridgeForERC20() public {
        // Build relayer refund leaf for DAI
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(dai), AMOUNT_TO_RETURN);

        // Relay root bundle via cross-domain admin
        bytes memory relayRootBundleData = abi.encodeWithSelector(
            spokePool.relayRootBundle.selector,
            root,
            mockTreeRoot
        );
        _callAsCrossDomainAdmin(relayRootBundleData);

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify bridge was called correctly for ERC20
        assertEq(polygonZkEvmBridge.bridgeAssetCallCount(), 1);
        (
            uint32 destinationNetwork,
            address destinationAddress,
            uint256 amount,
            address token,
            bool forceUpdateGlobalExitRoot,
            bytes memory permitData,
            uint256 value
        ) = polygonZkEvmBridge.lastBridgeAssetCall();

        assertEq(destinationNetwork, POLYGON_ZKEVM_L1_NETWORK_ID);
        assertEq(destinationAddress, hubPool);
        assertEq(amount, AMOUNT_TO_RETURN);
        assertEq(token, address(dai)); // ERC20 token address
        assertEq(forceUpdateGlobalExitRoot, true);
        assertEq(permitData, "");
        assertEq(value, 0); // No ETH sent for ERC20
    }
}
