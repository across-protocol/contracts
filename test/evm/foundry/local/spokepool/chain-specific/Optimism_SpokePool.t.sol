// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

// OpenZeppelin crosschain errors
import "@openzeppelin/contracts-v4/crosschain/errors.sol";

// Contracts under test
import { Optimism_SpokePool } from "../../../../../../contracts/Optimism_SpokePool.sol";
import { Ovm_SpokePool } from "../../../../../../contracts/Ovm_SpokePool.sol";
import { SpokePool } from "../../../../../../contracts/SpokePool.sol";
import { SpokePoolInterface } from "../../../../../../contracts/interfaces/SpokePoolInterface.sol";

// Mocks
import { MockBedrockL2StandardBridge, MockBedrockCrossDomainMessenger } from "../../../../../../contracts/test/MockBedrockStandardBridge.sol";
import { MockCCTPMessenger, MockCCTPMinter } from "../../../../../../contracts/test/MockCCTP.sol";
import { MintableERC20 } from "../../../../../../contracts/test/MockERC20.sol";
import { WETH9 } from "../../../../../../contracts/external/WETH9.sol";

// Utils
import { MerkleTreeUtils } from "../../../utils/MerkleTreeUtils.sol";

/**
 * @title Optimism_SpokePoolTest
 * @notice Foundry tests for Optimism_SpokePool, ported from Hardhat tests.
 * @dev Tests admin functions, token bridging via L2StandardBridge, and cross-domain messaging.
 *
 * Hardhat source: test/evm/hardhat/chain-specific-spokepools/Optimism_SpokePool.ts
 * Tests migrated:
 *   1. Only cross domain owner upgrade logic contract
 *   2. Only cross domain owner can set l1GasLimit
 *   3. Only cross domain owner can set token bridge address for L2 token
 *   4. Only cross domain owner can set the cross domain admin
 *   5. Only cross domain owner can set the hub pool address (withdrawal recipient)
 *   6. Only cross domain owner can initialize a relayer refund
 *   7. Only owner can delete a relayer refund
 *   8. Only owner can set a remote L1 token
 *   9. Bridge tokens to hub pool correctly calls the Standard L2 Bridge for ERC20
 *  10. If remote L1 token is set for native L2 token, then bridge calls bridgeERC20To instead of withdrawTo
 *  11. Bridge tokens to hub pool correctly calls an alternative L2 Gateway router
 *  12. Bridge ETH to hub pool correctly calls the Standard L2 Bridge for WETH, including unwrap
 */
contract Optimism_SpokePoolTest is Test {
    // ============ Test Constants ============

    uint256 constant AMOUNT_TO_RETURN = 1 ether;
    uint256 constant AMOUNT_HELD_BY_POOL = 100 ether;
    uint32 constant TEST_DEPOSIT_QUOTE_TIME_BUFFER = 1 hours;
    uint32 constant TEST_FILL_DEADLINE_BUFFER = 9 hours;
    uint32 constant DEFAULT_L1_GAS = 5_000_000;

    // Optimism L2 precompile addresses
    address constant L2_CROSS_DOMAIN_MESSENGER = 0x4200000000000000000000000000000000000007;
    address constant L2_STANDARD_BRIDGE = 0x4200000000000000000000000000000000000010;
    address constant L2_ETH = 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000;

    // ============ Contracts ============

    Optimism_SpokePool public spokePool;
    Optimism_SpokePool public spokePoolImplementation;

    // ============ Mocks ============

    WETH9 public weth;
    MintableERC20 public dai;
    MintableERC20 public usdc;
    MockBedrockL2StandardBridge public l2StandardBridge;
    MockBedrockCrossDomainMessenger public crossDomainMessenger;
    MockCCTPMessenger public cctpMessenger;
    MockCCTPMinter public cctpMinter;

    // ============ Addresses ============

    address public owner;
    address public relayer;
    address public rando;
    address public hubPool;

    // L2 token addresses (mocked)
    address public l2Dai;
    address public l2Usdc;

    // ============ Test State ============

    bytes32 public mockTreeRoot;

    // ============ Events ============

    event ERC20WithdrawalInitiated(address indexed l2Token, address indexed to, uint256 amount);

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

        // Create L2 token addresses
        l2Dai = makeAddr("l2Dai");
        l2Usdc = address(usdc);

        // Deploy mocks and place them at the expected precompile addresses
        l2StandardBridge = new MockBedrockL2StandardBridge();
        vm.etch(L2_STANDARD_BRIDGE, address(l2StandardBridge).code);
        l2StandardBridge = MockBedrockL2StandardBridge(L2_STANDARD_BRIDGE);

        crossDomainMessenger = new MockBedrockCrossDomainMessenger();
        vm.etch(L2_CROSS_DOMAIN_MESSENGER, address(crossDomainMessenger).code);
        crossDomainMessenger = MockBedrockCrossDomainMessenger(L2_CROSS_DOMAIN_MESSENGER);

        // Deploy CCTP mocks
        cctpMinter = new MockCCTPMinter();
        cctpMessenger = new MockCCTPMessenger(cctpMinter);
        cctpMinter.setBurnLimit(1_000_000e6);

        // Deploy Optimism SpokePool implementation
        spokePoolImplementation = new Optimism_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER,
            IERC20(address(usdc)),
            cctpMessenger
        );

        // Deploy proxy
        bytes memory initData = abi.encodeCall(Optimism_SpokePool.initialize, (0, owner, hubPool));
        ERC1967Proxy proxy = new ERC1967Proxy(address(spokePoolImplementation), initData);
        spokePool = Optimism_SpokePool(payable(address(proxy)));

        // Seed SpokePool with tokens and ETH for WETH conversion
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
    function _executeAsCrossDomainAdmin(bytes memory data) internal {
        crossDomainMessenger.impersonateCall{ value: 0 }(address(spokePool), data);
    }

    /**
     * @notice Sets the xDomainMessageSender and calls the spoke pool as the messenger
     */
    function _callAsCrossDomainMessenger(bytes memory data) internal {
        // First set the xDomainMessageSender by making an impersonateCall from owner
        vm.prank(owner);
        crossDomainMessenger.impersonateCall{ value: 0 }(address(spokePool), data);
    }

    // ============ Upgrade Tests ============

    function test_onlyCrossDomainOwnerCanUpgrade() public {
        // Deploy new implementation
        Optimism_SpokePool newImplementation = new Optimism_SpokePool(
            address(weth),
            TEST_DEPOSIT_QUOTE_TIME_BUFFER,
            TEST_FILL_DEADLINE_BUFFER,
            IERC20(address(usdc)),
            cctpMessenger
        );

        // Attempt upgrade from random address should fail with NotCrossChainCall
        vm.prank(rando);
        vm.expectRevert(NotCrossChainCall.selector);
        spokePool.upgradeTo(address(newImplementation));

        // Attempt upgrade from messenger but with wrong xDomainMessageSender should fail
        // The revert happens inside impersonateCall, but the call still reverts
        vm.prank(rando);
        vm.expectRevert(Ovm_SpokePool.NotCrossDomainAdmin.selector);
        crossDomainMessenger.impersonateCall(
            address(spokePool),
            abi.encodeCall(spokePool.upgradeTo, (address(newImplementation)))
        );

        // Upgrade from cross domain admin (owner) should succeed
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.upgradeTo, (address(newImplementation))));
    }

    // ============ Admin Function Tests ============

    function test_onlyCrossDomainOwnerCanSetL1GasLimit() public {
        uint32 newL1Gas = 1342;

        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.setL1GasLimit(newL1Gas);

        // Should succeed from cross domain admin
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.setL1GasLimit, (newL1Gas)));

        assertEq(spokePool.l1Gas(), newL1Gas);
    }

    function test_onlyCrossDomainOwnerCanSetTokenBridge() public {
        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.setTokenBridge(l2Dai, rando);

        // Should succeed from cross domain admin
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.setTokenBridge, (l2Dai, rando)));

        assertEq(spokePool.tokenBridges(l2Dai), rando);
    }

    function test_onlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.setCrossDomainAdmin(rando);

        // Should succeed from cross domain admin
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.setCrossDomainAdmin, (rando)));

        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function test_onlyCrossDomainOwnerCanSetWithdrawalRecipient() public {
        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.setWithdrawalRecipient(rando);

        // Should succeed from cross domain admin
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.setWithdrawalRecipient, (rando)));

        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function test_onlyCrossDomainOwnerCanRelayRootBundle() public {
        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Should succeed from cross domain admin
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot)));

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function test_onlyCrossDomainOwnerCanDeleteRootBundle() public {
        // First, relay a root bundle
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot)));

        // Attempt to delete from non-admin should fail
        vm.expectRevert();
        spokePool.emergencyDeleteRootBundle(0);

        // Should succeed from cross domain admin
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.emergencyDeleteRootBundle, (0)));

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    function test_onlyCrossDomainOwnerCanSetRemoteL1Token() public {
        // Initially should be zero address
        assertEq(spokePool.remoteL1Tokens(l2Dai), address(0));

        // Attempt from non-admin should fail
        vm.expectRevert();
        spokePool.setRemoteL1Token(l2Dai, rando);

        // Should succeed from cross domain admin
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.setRemoteL1Token, (l2Dai, rando)));

        assertEq(spokePool.remoteL1Tokens(l2Dai), rando);
    }

    // ============ Bridge Tokens Tests ============

    function test_bridgeTokensViaStandardBridgeForERC20() public {
        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), l2Dai, AMOUNT_TO_RETURN);

        // Relay root bundle
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot)));

        // Mint l2Dai tokens to spoke pool (since l2Dai is a separate address)
        vm.etch(l2Dai, address(dai).code);
        MintableERC20(l2Dai).mint(address(spokePool), AMOUNT_HELD_BY_POOL);

        // Expect ERC20WithdrawalInitiated event from L2StandardBridge
        vm.expectEmit(true, true, false, true, L2_STANDARD_BRIDGE);
        emit ERC20WithdrawalInitiated(l2Dai, hubPool, AMOUNT_TO_RETURN);

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }

    function test_bridgeTokensCallsBridgeERC20ToWhenRemoteL1TokenSet() public {
        // Use dai.address as the L2 token (native L2 token scenario)
        address nativeL2Token = address(dai);

        // Deploy a token to use as the remote L1 token
        MintableERC20 remoteL1TokenContract = new MintableERC20("Remote L1 Token", "RL1", 18);
        address remoteL1Token = address(remoteL1TokenContract);

        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), nativeL2Token, AMOUNT_TO_RETURN);

        // Set remote L1 token mapping
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.setRemoteL1Token, (nativeL2Token, remoteL1Token)));

        // Relay root bundle
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot)));

        // Mint remoteL1Token to the standard bridge to simulate the bridgeERC20To behavior
        // The mock bridge transfers remoteL1Token to the recipient
        remoteL1TokenContract.mint(L2_STANDARD_BRIDGE, AMOUNT_TO_RETURN);

        // Note: In the real implementation, bridgeERC20To is called which requires approval
        // and transfers tokens. Our mock implements this behavior.

        // Execute leaf - this should call bridgeERC20To instead of withdrawTo
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify the spoke pool gave allowance to the bridge and tokens were transferred
        // The mock bridge pulls tokens from the spoke pool and sends remoteL1Token to recipient
        assertEq(remoteL1TokenContract.balanceOf(hubPool), AMOUNT_TO_RETURN);
    }

    function test_bridgeTokensViaAlternativeL2Bridge() public {
        // Deploy alternative bridge
        MockBedrockL2StandardBridge altL2Bridge = new MockBedrockL2StandardBridge();

        // Build relayer refund leaf
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), l2Dai, AMOUNT_TO_RETURN);

        // Relay root bundle
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot)));

        // Set alternative token bridge
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.setTokenBridge, (l2Dai, address(altL2Bridge))));

        // Mint l2Dai tokens to spoke pool
        vm.etch(l2Dai, address(dai).code);
        MintableERC20(l2Dai).mint(address(spokePool), AMOUNT_HELD_BY_POOL);

        // Expect ERC20WithdrawalInitiated event from alternative bridge (not the standard one)
        vm.expectEmit(true, true, false, true, address(altL2Bridge));
        emit ERC20WithdrawalInitiated(l2Dai, hubPool, AMOUNT_TO_RETURN);

        // Execute leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());
    }

    function test_bridgeETHViaStandardBridgeForWETH() public {
        // Build relayer refund leaf for WETH
        (SpokePoolInterface.RelayerRefundLeaf memory leaf, bytes32 root) = MerkleTreeUtils
            .buildRelayerRefundLeafAndRoot(spokePool.chainId(), address(weth), AMOUNT_TO_RETURN);

        // Relay root bundle
        _callAsCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (root, mockTreeRoot)));

        // Record WETH balance before
        uint256 wethBalanceBefore = weth.balanceOf(address(spokePool));

        // Execute leaf - this should unwrap WETH to ETH and bridge via L2StandardBridge
        // The bridge's withdrawTo is called with msg.value for ETH
        vm.expectEmit(true, true, false, true, L2_STANDARD_BRIDGE);
        emit ERC20WithdrawalInitiated(L2_ETH, hubPool, AMOUNT_TO_RETURN);

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, MerkleTreeUtils.emptyProof());

        // Verify WETH was unwrapped (balance decreased)
        uint256 wethBalanceAfter = weth.balanceOf(address(spokePool));
        assertEq(wethBalanceBefore - wethBalanceAfter, AMOUNT_TO_RETURN);
    }
}
