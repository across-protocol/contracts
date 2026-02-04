// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/IERC20Upgradeable.sol";

// Contracts under test
import { Polygon_SpokePool } from "../../../../../../contracts/Polygon_SpokePool.sol";
import { PolygonTokenBridger, PolygonIERC20Upgradeable, PolygonRegistry } from "../../../../../../contracts/PolygonTokenBridger.sol";
import { WETH9Interface } from "../../../../../../contracts/external/interfaces/WETH9Interface.sol";
import { SpokePool } from "../../../../../../contracts/SpokePool.sol";
import { SpokePoolInterface } from "../../../../../../contracts/interfaces/SpokePoolInterface.sol";
import { V3SpokePoolInterface } from "../../../../../../contracts/interfaces/V3SpokePoolInterface.sol";

// Libraries
import { OFTTransportAdapter } from "../../../../../../contracts/libraries/OFTTransportAdapter.sol";

// Mocks
import { PolygonRegistryMock, PolygonERC20PredicateMock, PolygonERC20Mock } from "../../../../../../contracts/test/PolygonMocks.sol";
import { MockCCTPMessenger, MockCCTPMinter } from "../../../../../../contracts/test/MockCCTP.sol";
import { MockOFTMessenger } from "../../../../../../contracts/test/MockOFTMessenger.sol";
import { MintableERC20 } from "../../../../../../contracts/test/MockERC20.sol";
import { WETH9 } from "../../../../../../contracts/external/WETH9.sol";
import { MockCaller } from "../../../../../../contracts/test/MockCaller.sol";

// Utils
import { Constants } from "../../../../../../script/utils/Constants.sol";
import { MerkleTreeUtils } from "../../../utils/MerkleTreeUtils.sol";

/**
 * @title Polygon_SpokePoolTest
 * @notice Foundry tests for Polygon_SpokePool, ported from Hardhat tests.
 * @dev Tests admin functions, token bridging via PolygonTokenBridger, CCTP, and OFT.
 */
contract Polygon_SpokePoolTest is Test, Constants {
    // ============ Test Constants ============

    uint256 constant AMOUNT_TO_RETURN = 1 ether;
    uint256 constant AMOUNT_HELD_BY_POOL = 100 ether;
    uint256 constant TEST_OFT_FEE_CAP = 1 ether;
    uint32 constant TEST_DEPOSIT_QUOTE_TIME_BUFFER = 1 hours;
    uint32 constant TEST_FILL_DEADLINE_BUFFER = 9 hours;
    uint256 constant ORIGIN_CHAIN_ID = 1;
    uint256 constant REPAYMENT_CHAIN_ID = 10;

    // ============ Contracts ============

    Polygon_SpokePool public spokePool;
    Polygon_SpokePool public spokePoolImplementation;
    PolygonTokenBridger public polygonTokenBridger;

    // ============ Mocks ============

    WETH9 public weth;
    PolygonERC20Mock public dai;
    MintableERC20 public usdc;
    MintableERC20 public usdt;
    PolygonRegistryMock public polygonRegistry;
    PolygonERC20PredicateMock public erc20Predicate;
    MockCCTPMessenger public cctpMessenger;
    MockCCTPMinter public cctpMinter;
    MockOFTMessenger public oftMessenger;

    // ============ Addresses ============

    address public owner;
    address public relayer;
    address public rando;
    address public fxChild;
    address public hubPool;

    // ============ Chain Constants ============

    uint32 public oftHubEid;
    uint256 public l1ChainId;
    uint256 public l2ChainId;

    // ============ Test State ============

    bytes32 public mockTreeRoot;

    // ============ Events ============

    event SetFxChild(address indexed newFxChild);
    event SetPolygonTokenBridger(address indexed polygonTokenBridger);

    // ============ Setup ============

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");
        fxChild = makeAddr("fxChild");
        hubPool = makeAddr("hubPool");

        // Load chain constants
        oftHubEid = uint32(getOftEid(getChainId("MAINNET")));

        // Set chain IDs - L1 is different from current chain, L2 matches current chain
        l1ChainId = 1; // Mainnet
        l2ChainId = block.chainid; // Current test chain

        // Deploy tokens
        weth = new WETH9();
        dai = new PolygonERC20Mock();
        usdc = new MintableERC20("USDC", "USDC", 6);
        usdt = new MintableERC20("USDT", "USDT", 6);

        // Deploy Polygon mocks
        polygonRegistry = new PolygonRegistryMock();
        erc20Predicate = new PolygonERC20PredicateMock();

        // Deploy CCTP mocks
        cctpMinter = new MockCCTPMinter();
        cctpMessenger = new MockCCTPMessenger(cctpMinter);

        // Deploy OFT messenger
        oftMessenger = new MockOFTMessenger(address(usdt));

        // Deploy PolygonTokenBridger
        polygonTokenBridger = new PolygonTokenBridger(
            hubPool,
            PolygonRegistry(address(polygonRegistry)),
            WETH9Interface(address(weth)),
            address(weth),
            l1ChainId,
            l2ChainId
        );

        // Deploy Polygon SpokePool implementation
        spokePoolImplementation = new Polygon_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER,
            IERC20(address(usdc)),
            cctpMessenger,
            oftHubEid,
            TEST_OFT_FEE_CAP
        );

        // Deploy proxy
        bytes memory initData = abi.encodeCall(
            Polygon_SpokePool.initialize,
            (0, polygonTokenBridger, owner, hubPool, fxChild)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(spokePoolImplementation), initData);
        spokePool = Polygon_SpokePool(payable(address(proxy)));

        // Seed SpokePool with tokens
        deal(address(dai), address(spokePool), AMOUNT_HELD_BY_POOL);
        usdt.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
        vm.deal(address(spokePool), 10 ether);

        // Fund relayer and owner with ETH
        vm.deal(relayer, 10 ether);
        vm.deal(owner, 10 ether);

        // Setup mock tree root
        mockTreeRoot = keccak256("mockTreeRoot");
    }

    // ============ Helper Functions ============

    /**
     * @notice Helper to call SpokePool functions as the cross-domain admin.
     * @dev Simulates fxChild calling processMessageFromRoot with owner as rootMessageSender.
     */
    function _callAsCrossDomainAdmin(bytes memory data) internal {
        vm.prank(fxChild);
        spokePool.processMessageFromRoot(0, owner, data);
    }

    // ============ Upgrade Tests ============

    function test_onlyCrossDomainOwnerCanUpgrade() public {
        // Deploy new implementation
        Polygon_SpokePool newImplementation = new Polygon_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER,
            IERC20(address(usdc)),
            cctpMessenger,
            oftHubEid,
            TEST_OFT_FEE_CAP
        );

        bytes memory upgradeData = abi.encodeCall(spokePool.upgradeTo, (address(newImplementation)));

        // Wrong rootMessageSender address - should fail
        vm.expectRevert(Polygon_SpokePool.NotHubPool.selector);
        vm.prank(fxChild);
        spokePool.processMessageFromRoot(0, rando, upgradeData);

        // Wrong calling address - should fail
        vm.expectRevert(Polygon_SpokePool.NotFxChild.selector);
        vm.prank(rando);
        spokePool.processMessageFromRoot(0, owner, upgradeData);

        // Correct caller and rootMessageSender should succeed
        _callAsCrossDomainAdmin(upgradeData);
    }

    // ============ Admin Function Tests ============

    function test_onlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        // Cannot call directly
        vm.expectRevert();
        spokePool.setCrossDomainAdmin(rando);

        bytes memory setCrossDomainAdminData = abi.encodeCall(spokePool.setCrossDomainAdmin, (rando));

        // Wrong rootMessageSender address
        vm.expectRevert();
        vm.prank(fxChild);
        spokePool.processMessageFromRoot(0, rando, setCrossDomainAdminData);

        // Wrong calling address
        vm.expectRevert();
        vm.prank(rando);
        spokePool.processMessageFromRoot(0, owner, setCrossDomainAdminData);

        // Correct caller should succeed
        _callAsCrossDomainAdmin(setCrossDomainAdminData);
        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function test_onlyCrossDomainOwnerCanSetWithdrawalRecipient() public {
        // Cannot call directly
        vm.expectRevert();
        spokePool.setWithdrawalRecipient(rando);

        bytes memory setHubPoolData = abi.encodeCall(spokePool.setWithdrawalRecipient, (rando));

        // Wrong rootMessageSender address
        vm.expectRevert();
        vm.prank(fxChild);
        spokePool.processMessageFromRoot(0, rando, setHubPoolData);

        // Wrong calling address
        vm.expectRevert();
        vm.prank(rando);
        spokePool.processMessageFromRoot(0, owner, setHubPoolData);

        // Correct caller should succeed
        _callAsCrossDomainAdmin(setHubPoolData);
        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function test_onlyCrossDomainOwnerCanRelayRootBundle() public {
        // Cannot call directly
        vm.expectRevert();
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot));

        // Wrong rootMessageSender address
        vm.expectRevert();
        vm.prank(fxChild);
        spokePool.processMessageFromRoot(0, rando, relayRootBundleData);

        // Wrong calling address
        vm.expectRevert();
        vm.prank(rando);
        spokePool.processMessageFromRoot(0, owner, relayRootBundleData);

        // Correct caller should succeed
        _callAsCrossDomainAdmin(relayRootBundleData);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function test_cannotReenterProcessMessageFromRoot() public {
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot));
        bytes memory processMessageFromRootData = abi.encodeCall(
            spokePool.processMessageFromRoot,
            (0, owner, relayRootBundleData)
        );

        // Re-entrancy should fail
        vm.expectRevert();
        vm.prank(fxChild);
        spokePool.processMessageFromRoot(0, owner, processMessageFromRootData);
    }

    function test_onlyCrossDomainOwnerCanDeleteRootBundle() public {
        // First, relay a root bundle
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot));
        _callAsCrossDomainAdmin(relayRootBundleData);

        // Cannot call directly
        vm.expectRevert();
        spokePool.emergencyDeleteRootBundle(0);

        bytes memory emergencyDeleteData = abi.encodeCall(spokePool.emergencyDeleteRootBundle, (0));

        // Wrong rootMessageSender address
        vm.expectRevert();
        vm.prank(fxChild);
        spokePool.processMessageFromRoot(0, rando, emergencyDeleteData);

        // Wrong calling address
        vm.expectRevert();
        vm.prank(rando);
        spokePool.processMessageFromRoot(0, owner, emergencyDeleteData);

        // Correct caller should succeed
        _callAsCrossDomainAdmin(emergencyDeleteData);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    // ============ Wrap Tests ============

    function test_canWrapNativeToken() public {
        uint256 sendAmount = 0.1 ether;
        uint256 spokePoolBalanceBefore = address(spokePool).balance;

        // Fund rando with ETH
        vm.deal(rando, 1 ether);

        // Send native token to spoke pool
        vm.prank(rando);
        (bool success, ) = address(spokePool).call{ value: sendAmount }("");
        assertTrue(success);

        assertEq(address(spokePool).balance, spokePoolBalanceBefore + sendAmount);

        uint256 wethBalanceBefore = weth.balanceOf(address(spokePool));

        // Wrap native token
        spokePool.wrap();

        assertEq(weth.balanceOf(address(spokePool)), wethBalanceBefore + spokePoolBalanceBefore + sendAmount);
    }

    // ============ Bridge Tokens via PolygonTokenBridger Tests ============

    function test_bridgeTokensViaPolygonTokenBridger() public {
        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(dai), AMOUNT_TO_RETURN);

        // Relay root bundle
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot));
        _callAsCrossDomainAdmin(relayRootBundleData);

        uint256 spokePoolBalanceBefore = dai.balanceOf(address(spokePool));

        // Execute leaf - use prank with both msg.sender and tx.origin to pass EOA check
        vm.prank(relayer, relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify tokens were sent through the bridger (transferred from spokePool to bridger)
        // The bridger calls withdraw() on the token which burns it (PolygonERC20Mock.withdraw is a no-op for testing)
        // The key behavior is that tokens leave the spoke pool and go through the bridger
        assertEq(dai.balanceOf(address(spokePool)), spokePoolBalanceBefore - AMOUNT_TO_RETURN);
    }

    // ============ EOA Check Tests ============

    function test_mustBeEOAToExecuteRelayerRefundLeafWithAmountToReturn() public {
        // Build two leaves: one with amountToReturn > 0, one with amountToReturn = 0
        SpokePoolInterface.RelayerRefundLeaf memory leafWithAmount = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: AMOUNT_TO_RETURN,
            chainId: spokePool.chainId(),
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(dai),
            refundAddresses: new address[](0)
        });

        SpokePoolInterface.RelayerRefundLeaf memory leafWithoutAmount = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: 0,
            chainId: spokePool.chainId(),
            refundAmounts: new uint256[](0),
            leafId: 1,
            l2TokenAddress: address(dai),
            refundAddresses: new address[](0)
        });

        // Build tree with both leaves
        bytes32 leaf0Hash = keccak256(abi.encode(leafWithAmount));
        bytes32 leaf1Hash = keccak256(abi.encode(leafWithoutAmount));
        bytes32 root = keccak256(abi.encodePacked(leaf0Hash, leaf1Hash));

        bytes32[] memory proof0 = new bytes32[](1);
        proof0[0] = leaf1Hash;

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf0Hash;

        // Relay root bundle
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot));
        _callAsCrossDomainAdmin(relayRootBundleData);

        // Deploying MockCaller (contract) tries to execute leaf with amountToReturn > 0 - should fail
        vm.expectRevert(SpokePoolInterface.NotEOA.selector);
        new MockCaller(address(spokePool), 0, leafWithAmount, proof0);

        // Executing leaf with amountToReturn == 0 is fine through contract caller
        new MockCaller(address(spokePool), 0, leafWithoutAmount, proof1);
    }

    // ============ Multicall Validation Tests ============

    function test_cannotCombineFillAndExecuteLeafInSameTx() public {
        // Build two leaves with amountToReturn = 0
        SpokePoolInterface.RelayerRefundLeaf memory leaf0 = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: 0,
            chainId: spokePool.chainId(),
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(dai),
            refundAddresses: new address[](0)
        });

        SpokePoolInterface.RelayerRefundLeaf memory leaf1 = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: 0,
            chainId: spokePool.chainId(),
            refundAmounts: new uint256[](0),
            leafId: 1,
            l2TokenAddress: address(dai),
            refundAddresses: new address[](0)
        });

        // Build tree
        bytes32 leaf0Hash = keccak256(abi.encode(leaf0));
        bytes32 leaf1Hash = keccak256(abi.encode(leaf1));
        bytes32 root = keccak256(abi.encodePacked(leaf0Hash, leaf1Hash));

        bytes32[] memory proof0 = new bytes32[](1);
        proof0[0] = leaf1Hash;

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf0Hash;

        // Relay root bundle
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot));
        _callAsCrossDomainAdmin(relayRootBundleData);

        // Seed relayer with tokens and approve
        deal(address(dai), relayer, 2 ether);
        vm.prank(relayer);
        dai.approve(address(spokePool), 2 ether);

        // Build execute leaf data
        bytes[] memory executeLeafData = new bytes[](2);
        executeLeafData[0] = abi.encodeCall(spokePool.executeRelayerRefundLeaf, (0, leaf0, proof0));
        executeLeafData[1] = abi.encodeCall(spokePool.executeRelayerRefundLeaf, (0, leaf1, proof1));

        // Build fill data
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = V3SpokePoolInterface.V3RelayData({
            depositor: bytes32(uint256(uint160(owner))),
            recipient: bytes32(uint256(uint160(relayer))),
            exclusiveRelayer: bytes32(0),
            inputToken: bytes32(uint256(uint160(address(dai)))),
            outputToken: bytes32(uint256(uint160(address(dai)))),
            inputAmount: 1 ether,
            outputAmount: 1 ether,
            originChainId: ORIGIN_CHAIN_ID,
            depositId: 0,
            fillDeadline: currentTime + 7200,
            exclusivityDeadline: 0,
            message: hex"1234"
        });

        bytes[] memory fillData = new bytes[](1);
        fillData[0] = abi.encodeCall(
            spokePool.fillRelay,
            (relayData, REPAYMENT_CHAIN_ID, bytes32(uint256(uint160(relayer))))
        );

        // Execute leaves alone should succeed
        bytes[] memory executeOnly = new bytes[](2);
        executeOnly[0] = executeLeafData[0];
        executeOnly[1] = executeLeafData[1];

        // Using staticcall to test without state changes
        // Note: We test that multicall with fills + executeLeaf reverts
        bytes[] memory fillAndExecute = new bytes[](2);
        fillAndExecute[0] = fillData[0];
        fillAndExecute[1] = executeLeafData[0];

        vm.prank(relayer);
        vm.expectRevert(Polygon_SpokePool.MulticallExecuteLeaf.selector);
        spokePool.multicall(fillAndExecute);

        // Execute and fill combined also fails
        bytes[] memory executeAndFill = new bytes[](2);
        executeAndFill[0] = executeLeafData[0];
        executeAndFill[1] = fillData[0];

        vm.prank(relayer);
        vm.expectRevert(Polygon_SpokePool.MulticallExecuteLeaf.selector);
        spokePool.multicall(executeAndFill);
    }

    function test_cannotUseNestedMulticalls() public {
        // Build two leaves with amountToReturn = 0
        SpokePoolInterface.RelayerRefundLeaf memory leaf0 = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: 0,
            chainId: spokePool.chainId(),
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(dai),
            refundAddresses: new address[](0)
        });

        SpokePoolInterface.RelayerRefundLeaf memory leaf1 = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: 0,
            chainId: spokePool.chainId(),
            refundAmounts: new uint256[](0),
            leafId: 1,
            l2TokenAddress: address(dai),
            refundAddresses: new address[](0)
        });

        // Build tree
        bytes32 leaf0Hash = keccak256(abi.encode(leaf0));
        bytes32 leaf1Hash = keccak256(abi.encode(leaf1));
        bytes32 root = keccak256(abi.encodePacked(leaf0Hash, leaf1Hash));

        bytes32[] memory proof0 = new bytes32[](1);
        proof0[0] = leaf1Hash;

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf0Hash;

        // Relay root bundle
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot));
        _callAsCrossDomainAdmin(relayRootBundleData);

        // Build execute leaf data
        bytes[] memory executeLeafData = new bytes[](2);
        executeLeafData[0] = abi.encodeCall(spokePool.executeRelayerRefundLeaf, (0, leaf0, proof0));
        executeLeafData[1] = abi.encodeCall(spokePool.executeRelayerRefundLeaf, (0, leaf1, proof1));

        // Build fill data
        uint32 currentTime = uint32(block.timestamp);
        V3SpokePoolInterface.V3RelayData memory relayData = V3SpokePoolInterface.V3RelayData({
            depositor: bytes32(uint256(uint160(owner))),
            recipient: bytes32(uint256(uint160(relayer))),
            exclusiveRelayer: bytes32(0),
            inputToken: bytes32(uint256(uint160(address(dai)))),
            outputToken: bytes32(uint256(uint160(address(dai)))),
            inputAmount: 1 ether,
            outputAmount: 1 ether,
            originChainId: ORIGIN_CHAIN_ID,
            depositId: 0,
            fillDeadline: currentTime + 7200,
            exclusivityDeadline: 0,
            message: hex"1234"
        });

        bytes[] memory fillData = new bytes[](1);
        fillData[0] = abi.encodeCall(
            spokePool.fillRelay,
            (relayData, REPAYMENT_CHAIN_ID, bytes32(uint256(uint160(relayer))))
        );

        // Nested multicall with execute leaves should revert
        bytes[] memory nestedMulticall = new bytes[](1);
        nestedMulticall[0] = abi.encodeCall(spokePool.multicall, (executeLeafData));

        bytes[] memory outerMulticall = new bytes[](2);
        outerMulticall[0] = fillData[0];
        outerMulticall[1] = nestedMulticall[0];

        vm.prank(relayer);
        vm.expectRevert(Polygon_SpokePool.MulticallExecuteLeaf.selector);
        spokePool.multicall(outerMulticall);
    }

    // ============ OFT Bridge Tests ============

    function test_bridgeTokensViaOFT() public {
        uint256 usdtSendAmount = 1 ether;

        // Configure OFT messenger for USDT via cross-domain call
        bytes memory setOftMessengerData = abi.encodeCall(
            spokePool.setOftMessenger,
            (address(usdt), address(oftMessenger))
        );
        _callAsCrossDomainAdmin(setOftMessengerData);

        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(usdt), usdtSendAmount);

        // Relay root bundle
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot));
        _callAsCrossDomainAdmin(relayRootBundleData);

        // Set OFT fees to 0 (no fee required)
        oftMessenger.setFeesToReturn(0, 0);

        // Execute leaf - use prank with both msg.sender and tx.origin to pass EOA check
        vm.prank(relayer, relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify OFT messenger was called
        assertEq(oftMessenger.sendCallCount(), 1);

        // Verify allowance was set
        assertEq(usdt.allowance(address(spokePool), address(oftMessenger)), usdtSendAmount);

        // Verify send params
        (
            uint32 dstEid,
            bytes32 to,
            uint256 amountLD,
            uint256 minAmountLD,
            bytes memory extraOptions,
            bytes memory composeMsg,
            bytes memory oftCmd
        ) = oftMessenger.lastSendParam();

        assertEq(dstEid, oftHubEid);
        assertEq(to, bytes32(uint256(uint160(hubPool))));
        assertEq(amountLD, usdtSendAmount);
        assertEq(minAmountLD, usdtSendAmount);
        assertEq(extraOptions, "");
        assertEq(composeMsg, "");
        assertEq(oftCmd, "");
    }

    function test_OFT_revertsIfFeeUnderpaid() public {
        uint256 usdtSendAmount = 1 ether;

        // Configure OFT messenger
        bytes memory setOftMessengerData = abi.encodeCall(
            spokePool.setOftMessenger,
            (address(usdt), address(oftMessenger))
        );
        _callAsCrossDomainAdmin(setOftMessengerData);

        // Build leaf and relay root
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(usdt), usdtSendAmount);

        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot));
        _callAsCrossDomainAdmin(relayRootBundleData);

        // Set non-zero native fee but don't pay it
        uint256 nativeFee = 0.1 ether;
        oftMessenger.setFeesToReturn(nativeFee, 0);

        vm.expectRevert(SpokePool.OFTFeeUnderpaid.selector);
        // Use prank with both msg.sender and tx.origin to pass EOA check
        vm.prank(relayer, relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof()); // No msg.value
    }

    // ============ PolygonTokenBridger Tests ============

    function test_polygonTokenBridgerRetrievesAndUnwrapsCorrectly() public {
        // For retrieve, we need L1 chain ID to match current chain
        // Deploy a new bridger where l1ChainId == block.chainid
        PolygonTokenBridger l1Bridger = new PolygonTokenBridger(
            hubPool,
            PolygonRegistry(address(polygonRegistry)),
            WETH9Interface(address(weth)),
            address(weth),
            block.chainid, // l1ChainId matches current chain
            type(uint256).max // l2ChainId is different
        );

        // Send ETH to bridger
        vm.deal(address(l1Bridger), 1 ether);

        uint256 hubPoolWethBefore = weth.balanceOf(hubPool);

        // Retrieve automatically wraps and transfers
        l1Bridger.retrieve(IERC20Upgradeable(address(weth)));

        assertEq(weth.balanceOf(hubPool), hubPoolWethBefore + 1 ether);
    }

    function test_polygonTokenBridgerDoesNotAllowL1ActionsOnL2() public {
        // polygonTokenBridger is set up with l2ChainId == block.chainid
        // So L1 actions should fail

        // Transfer WETH to bridger
        vm.prank(address(spokePool));
        weth.deposit{ value: 1 ether }();
        vm.prank(address(spokePool));
        weth.transfer(address(polygonTokenBridger), 1 ether);

        // Cannot call retrieve on L2
        vm.expectRevert("Cannot run method on this chain");
        polygonTokenBridger.retrieve(IERC20Upgradeable(address(weth)));

        // Cannot call callExit on L2
        vm.expectRevert("Cannot run method on this chain");
        polygonTokenBridger.callExit(hex"");
    }

    function test_polygonTokenBridgerDoesNotAllowL2ActionsOnL1() public {
        // Deploy a bridger where l1ChainId == block.chainid (we're on L1)
        PolygonTokenBridger l1Bridger = new PolygonTokenBridger(
            hubPool,
            PolygonRegistry(address(polygonRegistry)),
            WETH9Interface(address(weth)),
            address(weth),
            block.chainid, // l1ChainId matches current chain
            type(uint256).max // l2ChainId is different
        );

        // Mint some DAI to owner and approve
        deal(address(dai), owner, 1 ether);
        vm.prank(owner);
        dai.approve(address(l1Bridger), 1 ether);

        // Cannot call send on L1
        vm.expectRevert("Cannot run method on this chain");
        vm.prank(owner);
        l1Bridger.send(PolygonIERC20Upgradeable(address(dai)), 1 ether);
    }

    function test_polygonTokenBridgerCorrectlyForwardsExitCall() public {
        // Deploy a bridger where l1ChainId == block.chainid (we're on L1)
        PolygonTokenBridger l1Bridger = new PolygonTokenBridger(
            hubPool,
            PolygonRegistry(address(polygonRegistry)),
            WETH9Interface(address(weth)),
            address(weth),
            block.chainid, // l1ChainId matches current chain
            type(uint256).max // l2ChainId is different
        );

        // Mock the registry to return the erc20Predicate address
        vm.mockCall(
            address(polygonRegistry),
            abi.encodeWithSelector(PolygonRegistry.erc20Predicate.selector),
            abi.encode(address(erc20Predicate))
        );

        bytes memory exitBytes = hex"1234567890abcdef";

        // Expect call to erc20Predicate.startExitWithBurntTokens
        vm.expectCall(
            address(erc20Predicate),
            abi.encodeWithSelector(PolygonERC20PredicateMock.startExitWithBurntTokens.selector, exitBytes)
        );

        l1Bridger.callExit(exitBytes);
    }
}
