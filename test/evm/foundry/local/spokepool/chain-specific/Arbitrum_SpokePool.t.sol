// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

// Contracts under test
import { Arbitrum_SpokePool } from "../../../../../../contracts/Arbitrum_SpokePool.sol";
import { SpokePool } from "../../../../../../contracts/SpokePool.sol";
import { SpokePoolInterface } from "../../../../../../contracts/interfaces/SpokePoolInterface.sol";

// Libraries
import { CrossDomainAddressUtils } from "../../../../../../contracts/libraries/CrossDomainAddressUtils.sol";
import { OFTTransportAdapter } from "../../../../../../contracts/libraries/OFTTransportAdapter.sol";

// Mocks
import { L2GatewayRouter } from "../../../../../../contracts/test/ArbitrumMocks.sol";
import { MockCCTPMessenger, MockCCTPMinter } from "../../../../../../contracts/test/MockCCTP.sol";
import { MockOFTMessenger } from "../../../../../../contracts/test/MockOFTMessenger.sol";
import { MintableERC20 } from "../../../../../../contracts/test/MockERC20.sol";
import { WETH9 } from "../../../../../../contracts/external/WETH9.sol";

// Utils
import { Constants } from "../../../../../../script/utils/Constants.sol";
import { MerkleTreeUtils } from "../../../utils/MerkleTreeUtils.sol";

/**
 * @title Arbitrum_SpokePoolTest
 * @notice Foundry tests for Arbitrum_SpokePool, ported from Hardhat tests.
 * @dev Tests admin functions, token bridging via Gateway, CCTP, and OFT.
 */
contract Arbitrum_SpokePoolTest is Test, Constants {
    // ============ Test Constants ============

    uint256 constant AMOUNT_TO_RETURN = 1 ether;
    uint256 constant AMOUNT_HELD_BY_POOL = 100 ether;
    uint256 constant TEST_OFT_FEE_CAP = 1 ether;
    uint32 constant TEST_DEPOSIT_QUOTE_TIME_BUFFER = 1 hours;
    uint32 constant TEST_FILL_DEADLINE_BUFFER = 9 hours;

    // ============ Contracts ============

    Arbitrum_SpokePool public spokePool;
    Arbitrum_SpokePool public spokePoolImplementation;

    // ============ Mocks ============

    WETH9 public weth;
    MintableERC20 public dai;
    MintableERC20 public usdc;
    MintableERC20 public usdt;
    L2GatewayRouter public l2GatewayRouter;
    MockCCTPMessenger public cctpMessenger;
    MockCCTPMinter public cctpMinter;
    MockOFTMessenger public oftMessenger;

    // ============ Addresses ============

    address public owner;
    address public relayer;
    address public rando;
    address public crossDomainAlias;
    address public hubPool;

    // L2 token addresses (mocked)
    address public l2Weth;
    address public l2Dai;
    address public l2Usdc;

    // ============ Chain Constants ============

    uint32 public oftHubEid;

    // ============ Test State ============

    bytes32 public mockTreeRoot;

    // ============ Setup ============

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");
        hubPool = makeAddr("hubPool");

        // Calculate cross domain alias (L1 to L2 address transformation)
        crossDomainAlias = CrossDomainAddressUtils.applyL1ToL2Alias(owner);

        // Load chain constants
        oftHubEid = uint32(getOftEid(getChainId("MAINNET")));

        // Deploy tokens
        weth = new WETH9();
        dai = new MintableERC20("DAI", "DAI", 18);
        usdc = new MintableERC20("USDC", "USDC", 6);
        usdt = new MintableERC20("USDT", "USDT", 6);

        // Create L2 token addresses
        l2Weth = address(weth);
        l2Dai = makeAddr("l2Dai");
        l2Usdc = address(usdc);

        // Deploy mocks
        l2GatewayRouter = new L2GatewayRouter();
        cctpMinter = new MockCCTPMinter();
        cctpMessenger = new MockCCTPMessenger(cctpMinter);
        oftMessenger = new MockOFTMessenger(address(usdt));

        // Setup L2 token mapping in gateway router
        l2GatewayRouter.setL2TokenAddress(address(dai), l2Dai);

        // Deploy Arbitrum SpokePool implementation
        spokePoolImplementation = new Arbitrum_SpokePool(
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
            Arbitrum_SpokePool.initialize,
            (0, address(l2GatewayRouter), owner, hubPool)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(spokePoolImplementation), initData);
        spokePool = Arbitrum_SpokePool(payable(address(proxy)));

        // Seed SpokePool with tokens
        dai.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
        usdt.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
        vm.deal(address(spokePool), 10 ether);

        // Fund relayer with ETH for OFT fee payments
        vm.deal(relayer, 10 ether);

        // Whitelist DAI token (as cross domain alias)
        vm.prank(crossDomainAlias);
        spokePool.whitelistToken(l2Dai, address(dai));

        // Setup mock tree root
        mockTreeRoot = keccak256("mockTreeRoot");
    }

    // ============ Upgrade Tests ============

    function test_onlyCrossDomainOwnerCanUpgrade() public {
        // Deploy new implementation
        Arbitrum_SpokePool newImplementation = new Arbitrum_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER,
            IERC20(address(usdc)),
            cctpMessenger,
            oftHubEid,
            TEST_OFT_FEE_CAP
        );

        // Attempt upgrade from non-cross-domain admin should fail
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.upgradeTo(address(newImplementation));

        // Upgrade from cross domain alias should succeed
        vm.prank(crossDomainAlias);
        spokePool.upgradeTo(address(newImplementation));
    }

    // ============ Admin Function Tests ============

    function test_onlyCrossDomainOwnerCanSetL2GatewayRouter() public {
        address newRouter = makeAddr("newRouter");

        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.setL2GatewayRouter(newRouter);

        // Should succeed from cross domain alias
        vm.prank(crossDomainAlias);
        spokePool.setL2GatewayRouter(newRouter);

        assertEq(spokePool.l2GatewayRouter(), newRouter);
    }

    function test_onlyCrossDomainOwnerCanWhitelistToken() public {
        address newL2Token = makeAddr("newL2Token");
        address newL1Token = makeAddr("newL1Token");

        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.whitelistToken(newL2Token, newL1Token);

        // Should succeed from cross domain alias
        vm.prank(crossDomainAlias);
        spokePool.whitelistToken(newL2Token, newL1Token);

        assertEq(spokePool.whitelistedTokens(newL2Token), newL1Token);
    }

    function test_onlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.setCrossDomainAdmin(rando);

        // Should succeed from cross domain alias
        vm.prank(crossDomainAlias);
        spokePool.setCrossDomainAdmin(rando);

        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function test_onlyCrossDomainOwnerCanSetWithdrawalRecipient() public {
        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.setWithdrawalRecipient(rando);

        // Should succeed from cross domain alias
        vm.prank(crossDomainAlias);
        spokePool.setWithdrawalRecipient(rando);

        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function test_onlyCrossDomainOwnerCanRelayRootBundle() public {
        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Should succeed from cross domain alias
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function test_onlyCrossDomainOwnerCanDeleteRootBundle() public {
        // First, relay a root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Attempt to delete from non-admin should fail
        vm.expectRevert();
        spokePool.emergencyDeleteRootBundle(0);

        // Should succeed from cross domain alias
        vm.prank(crossDomainAlias);
        spokePool.emergencyDeleteRootBundle(0);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    // ============ Bridge Tokens via Gateway Tests ============

    function test_bridgeTokensViaGateway() public {
        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), l2Dai, AMOUNT_TO_RETURN);

        // Relay root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Expect OutboundTransfer event from L2GatewayRouter
        // Event signature: OutboundTransfer(address indexed l1Token, address indexed to, uint256 amount)
        vm.expectEmit(true, true, false, true, address(l2GatewayRouter));
        emit L2GatewayRouter.OutboundTransfer(address(dai), hubPool, AMOUNT_TO_RETURN);

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }

    function test_bridgeTokensViaGateway_revertsIfTokenNotWhitelisted() public {
        // Build leaf with l2Dai
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), l2Dai, AMOUNT_TO_RETURN);

        // Relay root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Remove whitelist
        vm.prank(crossDomainAlias);
        spokePool.whitelistToken(l2Dai, address(0));

        // Should revert with "Uninitialized mainnet token"
        vm.expectRevert("Uninitialized mainnet token");
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Re-whitelist and execute should succeed
        vm.prank(crossDomainAlias);
        spokePool.whitelistToken(l2Dai, address(dai));

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }

    // ============ Bridge Tokens via OFT Tests ============

    function test_bridgeTokensViaOFT() public {
        uint256 usdtSendAmount = 1234567;

        // Setup OFT messenger
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(usdt), address(oftMessenger));

        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(usdt), usdtSendAmount);

        // Relay root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Set OFT fees (1 GWEI gas price * 200,000 gas cost)
        uint256 oftNativeFee = 1 gwei * 200_000;
        oftMessenger.setFeesToReturn(oftNativeFee, 0);

        // Execute leaf with msg.value for OFT fee
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf{ value: oftNativeFee }(0, leaf, MerkleTreeUtils.emptyProof());

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

    function test_OFT_revertsIfLzTokenFeeNotZero() public {
        uint256 usdtSendAmount = 1234567;

        // Setup OFT messenger
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(usdt), address(oftMessenger));

        // Build leaf and relay root
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(usdt), usdtSendAmount);

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Set non-zero lzTokenFee
        uint256 nativeFee = 0.1 ether;
        oftMessenger.setFeesToReturn(nativeFee, 1); // lzTokenFee = 1

        vm.expectRevert(OFTTransportAdapter.OftLzFeeNotZero.selector);
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf{ value: nativeFee }(0, leaf, MerkleTreeUtils.emptyProof());
    }

    function test_OFT_revertsIfFeeCapExceeded() public {
        uint256 usdtSendAmount = 1234567;

        // Setup OFT messenger
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(usdt), address(oftMessenger));

        // Build leaf and relay root
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(usdt), usdtSendAmount);

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Set native fee higher than cap (1 ETH)
        uint256 highNativeFee = 2 ether;
        oftMessenger.setFeesToReturn(highNativeFee, 0);

        vm.expectRevert(OFTTransportAdapter.OftFeeCapExceeded.selector);
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf{ value: highNativeFee }(0, leaf, MerkleTreeUtils.emptyProof());
    }

    function test_OFT_revertsIfFeeUnderpaid() public {
        uint256 usdtSendAmount = 1234567;

        // Setup OFT messenger
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(usdt), address(oftMessenger));

        // Build leaf and relay root
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(usdt), usdtSendAmount);

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Set valid native fee but don't pay it
        uint256 nativeFee = 0.1 ether;
        oftMessenger.setFeesToReturn(nativeFee, 0);

        vm.expectRevert(SpokePool.OFTFeeUnderpaid.selector);
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof()); // No msg.value
    }

    function test_OFT_revertsIfIncorrectAmountReceived() public {
        uint256 usdtSendAmount = 1234567;

        // Setup OFT messenger
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(usdt), address(oftMessenger));

        // Build leaf and relay root
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(usdt), usdtSendAmount);

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Set mismatched amounts (amountSentLD correct, amountReceivedLD wrong)
        oftMessenger.setFeesToReturn(0, 0);
        oftMessenger.setLDAmountsToReturn(usdtSendAmount, usdtSendAmount - 1);

        vm.expectRevert(OFTTransportAdapter.OftIncorrectAmountReceivedLD.selector);
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }

    function test_OFT_revertsIfIncorrectAmountSent() public {
        uint256 usdtSendAmount = 1234567;

        // Setup OFT messenger
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(usdt), address(oftMessenger));

        // Build leaf and relay root
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(usdt), usdtSendAmount);

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(root, mockTreeRoot);

        // Set mismatched amounts (amountSentLD wrong, amountReceivedLD correct)
        oftMessenger.setFeesToReturn(0, 0);
        oftMessenger.setLDAmountsToReturn(usdtSendAmount - 1, usdtSendAmount);

        vm.expectRevert(OFTTransportAdapter.OftIncorrectAmountSentLD.selector);
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }

    // ============ OFT Messenger Admin Tests ============

    function test_crossDomainOwnerCanSetAndRemoveOftMessenger() public {
        // Non-admin should fail
        vm.expectRevert();
        spokePool.setOftMessenger(address(usdt), address(oftMessenger));

        // Admin should succeed
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(usdt), address(oftMessenger));
        assertEq(spokePool.oftMessengers(address(usdt)), address(oftMessenger));

        // Non-admin remove should fail
        vm.expectRevert();
        spokePool.setOftMessenger(address(usdt), address(0));

        // Admin remove should succeed
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(usdt), address(0));
        assertEq(spokePool.oftMessengers(address(usdt)), address(0));
    }
}
