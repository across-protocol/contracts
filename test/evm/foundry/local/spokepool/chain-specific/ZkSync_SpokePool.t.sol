// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

// Contracts under test
import { ZkSync_SpokePool, ZkBridgeLike, IL2ETH, IL2AssetRouter } from "../../../../../../contracts/ZkSync_SpokePool.sol";
import { SpokePoolInterface } from "../../../../../../contracts/interfaces/SpokePoolInterface.sol";

// Libraries
import { CrossDomainAddressUtils } from "../../../../../../contracts/libraries/CrossDomainAddressUtils.sol";
import { ITokenMessenger } from "../../../../../../contracts/libraries/CircleCCTPAdapter.sol";

// Mocks
import { MockZkBridge, MockL2Eth } from "../../../../../../contracts/test/ZkSyncMocks.sol";
import { MockCCTPMessenger, MockCCTPMinter } from "../../../../../../contracts/test/MockCCTP.sol";
import { MintableERC20 } from "../../../../../../contracts/test/MockERC20.sol";
import { WETH9 } from "../../../../../../contracts/external/WETH9.sol";

// Utils
import { MerkleTreeUtils } from "../../../utils/MerkleTreeUtils.sol";

/**
 * @title ZkSync_SpokePoolTest
 * @notice Foundry tests for ZkSync_SpokePool, ported from Hardhat tests.
 * @dev Tests admin functions, token bridging via L2AssetRouter/custom USDC bridge, and ETH bridging.
 */
contract ZkSync_SpokePoolTest is Test {
    // ============ Test Constants ============

    uint256 constant AMOUNT_TO_RETURN = 1 ether;
    uint256 constant AMOUNT_HELD_BY_POOL = 100 ether;
    uint256 constant L1_CHAIN_ID = 1;
    uint32 constant TEST_DEPOSIT_QUOTE_TIME_BUFFER = 1 hours;
    uint32 constant TEST_FILL_DEADLINE_BUFFER = 9 hours;

    // ZkSync L2 ETH address
    address constant L2_ETH_ADDRESS = 0x000000000000000000000000000000000000800A;
    address constant L2_ASSET_ROUTER_ADDRESS = 0x0000000000000000000000000000000000010003;
    address constant L2_NATIVE_TOKEN_VAULT_ADDRESS = 0x0000000000000000000000000000000000010004;

    // ============ Contracts ============

    ZkSync_SpokePool public spokePool;
    ZkSync_SpokePool public spokePoolImplementation;

    // ============ Mocks ============

    WETH9 public weth;
    MintableERC20 public dai;
    MintableERC20 public usdc;
    MockZkBridge public zkUSDCBridge;
    MockL2Eth public l2Eth;
    MockCCTPMessenger public cctpMessenger;
    MockCCTPMinter public cctpMinter;

    // ============ Addresses ============

    address public owner;
    address public relayer;
    address public crossDomainAlias;
    address public hubPool;

    // L2 token addresses
    address public l2Dai;

    // ============ Test State ============

    bytes32 public mockTreeRoot;

    // ============ Setup ============

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        relayer = makeAddr("relayer");
        hubPool = makeAddr("hubPool");

        // Calculate cross domain alias (L1 to L2 address transformation - same as Arbitrum)
        crossDomainAlias = CrossDomainAddressUtils.applyL1ToL2Alias(owner);

        // Deploy tokens
        weth = new WETH9();
        dai = new MintableERC20("DAI", "DAI", 18);
        usdc = new MintableERC20("USDC", "USDC", 6);

        // Create L2 token addresses
        l2Dai = address(dai);

        // Deploy mocks
        zkUSDCBridge = new MockZkBridge();

        // Deploy mock L2 ETH at the correct address
        l2Eth = new MockL2Eth();
        vm.etch(L2_ETH_ADDRESS, address(l2Eth).code);
        vm.etch(L2_ASSET_ROUTER_ADDRESS, hex"00");

        // Deploy mock CCTP (for CCTP configuration tests)
        cctpMinter = new MockCCTPMinter();
        cctpMessenger = new MockCCTPMessenger(cctpMinter);

        // Deploy ZkSync SpokePool implementation with zkUSDCBridge (Circle Bridged USDC config)
        spokePoolImplementation = new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)),
            ZkBridgeLike(address(zkUSDCBridge)),
            L1_CHAIN_ID,
            ITokenMessenger(address(0)), // No CCTP
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );

        // Deploy proxy
        bytes memory initData = abi.encodeCall(ZkSync_SpokePool.initialize, (0, owner, hubPool));
        ERC1967Proxy proxy = new ERC1967Proxy(address(spokePoolImplementation), initData);
        spokePool = ZkSync_SpokePool(payable(address(proxy)));

        // Seed SpokePool with tokens
        dai.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
        usdc.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
        vm.deal(address(weth), AMOUNT_HELD_BY_POOL);
        weth.deposit{ value: AMOUNT_HELD_BY_POOL }();
        weth.transfer(address(spokePool), AMOUNT_HELD_BY_POOL);

        // Fund relayer with ETH
        vm.deal(relayer, 10 ether);

        // Setup mock tree root
        mockTreeRoot = keccak256("mockTreeRoot");
    }

    // ============ Upgrade Tests ============

    function test_onlyCrossDomainOwnerCanUpgrade() public {
        // Deploy new implementation
        ZkSync_SpokePool newImplementation = new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)),
            ZkBridgeLike(address(zkUSDCBridge)),
            L1_CHAIN_ID,
            ITokenMessenger(address(0)),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );

        // Attempt upgrade from non-cross-domain admin should fail
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.upgradeTo(address(newImplementation));

        // Upgrade from cross domain alias should succeed
        vm.prank(crossDomainAlias);
        spokePool.upgradeTo(address(newImplementation));
    }

    // ============ Admin Function Tests ============

    function test_onlyCrossDomainOwnerCanRelayRootBundle() public {
        // Build relayer refund leaf to get a valid root
        (, bytes32 root) = MerkleTreeUtils.buildRelayerRefundLeafAndRoot(spokePool.chainId(), l2Dai, AMOUNT_TO_RETURN);

        // Attempt from non-admin should fail
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Should succeed from cross domain alias
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);
    }

    // ============ Invalid USDC Bridge Configuration Tests ============

    function test_invalidUsdcBridgeConfiguration_neitherConfigured() public {
        // Configure neither zkUSDCBridge nor CCTP (misconfigured)
        vm.expectRevert(ZkSync_SpokePool.InvalidBridgeConfig.selector);
        new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)), // USDC is set
            ZkBridgeLike(address(0)), // No zkUSDCBridge
            L1_CHAIN_ID,
            ITokenMessenger(address(0)), // No CCTP
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );
    }

    function test_invalidUsdcBridgeConfiguration_bothConfigured() public {
        // Configure both zkUSDCBridge and CCTP (misconfigured)
        vm.expectRevert(ZkSync_SpokePool.InvalidBridgeConfig.selector);
        new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)), // USDC is set
            ZkBridgeLike(address(zkUSDCBridge)), // zkUSDCBridge set
            L1_CHAIN_ID,
            ITokenMessenger(address(cctpMessenger)), // CCTP also set
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );
    }

    function test_validUsdcBridgeConfiguration_onlyZkUsdcBridge() public {
        // Configure only zkUSDCBridge (valid)
        ZkSync_SpokePool impl = new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)),
            ZkBridgeLike(address(zkUSDCBridge)),
            L1_CHAIN_ID,
            ITokenMessenger(address(0)), // No CCTP
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );
        assertTrue(address(impl) != address(0));
    }

    function test_validUsdcBridgeConfiguration_onlyCctp() public {
        // Configure only CCTP (valid)
        ZkSync_SpokePool impl = new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)),
            ZkBridgeLike(address(0)), // No zkUSDCBridge
            L1_CHAIN_ID,
            ITokenMessenger(address(cctpMessenger)),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );
        assertTrue(address(impl) != address(0));
    }

    function test_validUsdcBridgeConfiguration_noUsdc() public {
        // Configure neither when USDC address is zero (valid - no USDC support)
        ZkSync_SpokePool impl = new ZkSync_SpokePool(
            address(weth),
            IERC20(address(0)), // No USDC
            ZkBridgeLike(address(0)),
            L1_CHAIN_ID,
            ITokenMessenger(address(0)),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );
        assertTrue(address(impl) != address(0));
    }

    // ============ Bridge Tokens via Standard L2 Bridge Tests ============

    function test_bridgeTokensViaStandardL2Bridge() public {
        bytes32 expectedAssetId = keccak256(abi.encode(L1_CHAIN_ID, L2_NATIVE_TOKEN_VAULT_ADDRESS, address(dai)));
        bytes memory expectedData = abi.encode(AMOUNT_TO_RETURN, hubPool, l2Dai);
        vm.mockCall(
            L2_ASSET_ROUTER_ADDRESS,
            abi.encodeWithSelector(IL2AssetRouter.l1TokenAddress.selector, l2Dai),
            abi.encode(address(dai))
        );
        vm.mockCall(
            L2_ASSET_ROUTER_ADDRESS,
            abi.encodeWithSelector(IL2AssetRouter.withdraw.selector, expectedAssetId, expectedData),
            abi.encode(bytes32(uint256(1)))
        );
        vm.expectCall(
            L2_ASSET_ROUTER_ADDRESS,
            abi.encodeWithSelector(IL2AssetRouter.withdraw.selector, expectedAssetId, expectedData)
        );

        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), l2Dai, AMOUNT_TO_RETURN);

        // Relay root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }

    function test_bridgeTokensViaStandardL2Bridge_revertsIfTokenMissingL1Mapping() public {
        vm.mockCall(
            L2_ASSET_ROUTER_ADDRESS,
            abi.encodeWithSelector(IL2AssetRouter.l1TokenAddress.selector, l2Dai),
            abi.encode(address(0))
        );

        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), l2Dai, AMOUNT_TO_RETURN);

        // Relay root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        vm.expectRevert(ZkSync_SpokePool.InvalidTokenAddress.selector);
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }

    function test_bridgeTokensViaStandardL2Bridge_zkSyncBridgedUsdcE() public {
        // Redeploy the SpokePool with usdc address -> 0x0 (no USDC set, standard bridge for all)
        ZkSync_SpokePool newImplementation = new ZkSync_SpokePool(
            address(weth),
            IERC20(address(0)), // No special USDC handling
            ZkBridgeLike(address(zkUSDCBridge)),
            L1_CHAIN_ID,
            ITokenMessenger(address(0)),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER
        );
        vm.prank(crossDomainAlias);
        spokePool.upgradeTo(address(newImplementation));

        bytes32 expectedAssetId = keccak256(abi.encode(L1_CHAIN_ID, L2_NATIVE_TOKEN_VAULT_ADDRESS, address(usdc)));
        bytes memory expectedData = abi.encode(AMOUNT_TO_RETURN, hubPool, address(usdc));
        vm.mockCall(
            L2_ASSET_ROUTER_ADDRESS,
            abi.encodeWithSelector(IL2AssetRouter.l1TokenAddress.selector, address(usdc)),
            abi.encode(address(usdc))
        );
        vm.mockCall(
            L2_ASSET_ROUTER_ADDRESS,
            abi.encodeWithSelector(IL2AssetRouter.withdraw.selector, expectedAssetId, expectedData),
            abi.encode(bytes32(uint256(1)))
        );
        vm.expectCall(
            L2_ASSET_ROUTER_ADDRESS,
            abi.encodeWithSelector(IL2AssetRouter.withdraw.selector, expectedAssetId, expectedData)
        );

        // Build relayer refund leaf for USDC
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(usdc), AMOUNT_TO_RETURN);

        // Relay root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }

    // ============ Bridge Tokens via Custom USDC Bridge Tests ============

    function test_bridgeTokensViaCustomUsdcBridge() public {
        // Build relayer refund leaf for USDC (uses zkUSDCBridge)
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(usdc), AMOUNT_TO_RETURN);

        // Relay root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Check allowance is zero before
        uint256 allowanceBefore = usdc.allowance(address(spokePool), address(zkUSDCBridge));
        assertEq(allowanceBefore, 0);

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify zkUSDCBridge.withdraw was called correctly
        assertEq(zkUSDCBridge.withdrawCallCount(), 1);
        (address l1Receiver, address l2Token, uint256 amount) = zkUSDCBridge.getWithdrawCall(0);
        assertEq(l1Receiver, hubPool);
        assertEq(l2Token, address(usdc));
        assertEq(amount, AMOUNT_TO_RETURN);

        // zkUSDCBridge is a mock, so tokens aren't actually moved and approval is intact
        uint256 allowanceAfter = usdc.allowance(address(spokePool), address(zkUSDCBridge));
        assertEq(allowanceAfter, AMOUNT_TO_RETURN);
    }

    // ============ Bridge ETH Tests ============

    function test_bridgeEthToHubPoolUnwrapsWeth() public {
        // Build relayer refund leaf for WETH
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(weth), AMOUNT_TO_RETURN);

        // Relay root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Track WETH balance before
        uint256 wethBalanceBefore = weth.balanceOf(address(spokePool));

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify WETH balance decreased (unwrapped)
        uint256 wethBalanceAfter = weth.balanceOf(address(spokePool));
        assertEq(wethBalanceBefore - wethBalanceAfter, AMOUNT_TO_RETURN);

        // Verify L2 ETH withdraw was called via vm.mockCall pattern
        // Since we etched the code, we need to check events or use vm.expectCall
        // The mock L2Eth at L2_ETH_ADDRESS should have been called
    }

    function test_bridgeEthToHubPoolCallsL2EthWithdraw() public {
        // Build relayer refund leaf for WETH
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(weth), AMOUNT_TO_RETURN);

        // Relay root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Expect the L2 ETH withdraw call
        vm.expectCall(L2_ETH_ADDRESS, AMOUNT_TO_RETURN, abi.encodeWithSelector(IL2ETH.withdraw.selector, hubPool));

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }
}
