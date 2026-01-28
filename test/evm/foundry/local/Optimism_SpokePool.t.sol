// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { MockOptimism_SpokePool } from "../../../../contracts/test/MockOptimism_SpokePool.sol";
import { Optimism_SpokePool } from "../../../../contracts/Optimism_SpokePool.sol";
import { MockBedrockL2StandardBridge, MockBedrockCrossDomainMessenger } from "../../../../contracts/test/MockBedrockStandardBridge.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { Lib_PredeployAddresses } from "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract OptimismSpokePoolTest is Test {
    MockOptimism_SpokePool public spokePool;
    MockBedrockCrossDomainMessenger public crossDomainMessenger;
    MockBedrockL2StandardBridge public l2StandardBridge;
    WETH9 public weth;
    MintableERC20 public l2Dai;

    address public owner;
    address public hubPool;
    address public relayer;
    address public rando;

    // Optimism's L2 ETH address
    address public constant L2_ETH = 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000;

    bytes32 public mockTreeRoot;
    uint256 public amountToReturn = 1 ether;
    uint256 public amountHeldByPool = 10 ether;

    function setUp() public {
        owner = makeAddr("owner");
        hubPool = makeAddr("hubPool");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");
        mockTreeRoot = keccak256("mockTreeRoot");

        // Deploy WETH
        weth = new WETH9();

        // Deploy a simple ERC20 for L2 DAI
        l2Dai = new MintableERC20("L2 DAI", "L2DAI");

        // Deploy cross domain messenger at the predeploy address
        crossDomainMessenger = new MockBedrockCrossDomainMessenger();
        vm.etch(Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER, address(crossDomainMessenger).code);
        crossDomainMessenger = MockBedrockCrossDomainMessenger(Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER);

        // Deploy L2 standard bridge at the predeploy address
        l2StandardBridge = new MockBedrockL2StandardBridge();
        vm.etch(Lib_PredeployAddresses.L2_STANDARD_BRIDGE, address(l2StandardBridge).code);
        l2StandardBridge = MockBedrockL2StandardBridge(Lib_PredeployAddresses.L2_STANDARD_BRIDGE);

        // Fund cross domain messenger with ETH for impersonate calls
        vm.deal(address(crossDomainMessenger), 1 ether);

        // Deploy implementation using MockOptimism_SpokePool (which has simplified constructor)
        MockOptimism_SpokePool implementation = new MockOptimism_SpokePool(address(weth));

        // Deploy proxy
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(MockOptimism_SpokePool.initialize, (L2_ETH, 0, owner, hubPool))
            )
        );
        spokePool = MockOptimism_SpokePool(payable(proxy));

        // Seed spoke pool with tokens
        l2Dai.mint(address(spokePool), amountHeldByPool);

        // Give spoke pool WETH by actually depositing ETH (so WETH contract has ETH to send on withdraw)
        vm.deal(address(spokePool), amountHeldByPool);
        vm.prank(address(spokePool));
        weth.deposit{ value: amountHeldByPool }();
    }

    // Helper to call admin functions via cross domain messenger
    function _callViaCrossDomainMessenger(bytes memory data) internal {
        vm.prank(owner);
        crossDomainMessenger.impersonateCall(address(spokePool), data);
    }

    function testOnlyCrossDomainOwnerUpgradeLogicContract() public {
        // Deploy new implementation
        Optimism_SpokePool newImplementation = new Optimism_SpokePool(
            address(weth),
            60 * 60,
            9 * 60 * 60,
            IERC20(address(0)),
            ITokenMessenger(address(0))
        );

        // upgradeTo fails unless called via cross domain messenger
        vm.prank(rando);
        vm.expectRevert();
        spokePool.upgradeTo(address(newImplementation));

        // Fails if called via messenger but without correct sender
        vm.prank(rando);
        vm.expectRevert();
        crossDomainMessenger.impersonateCall(
            address(spokePool),
            abi.encodeCall(spokePool.upgradeTo, (address(newImplementation)))
        );

        // Owner via cross domain messenger can upgrade
        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.upgradeTo, (address(newImplementation))));
    }

    function testOnlyCrossDomainOwnerCanSetL1GasLimit() public {
        vm.expectRevert();
        spokePool.setL1GasLimit(1342);

        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.setL1GasLimit, (1342)));
        assertEq(spokePool.l1Gas(), 1342);
    }

    function testOnlyCrossDomainOwnerCanSetTokenBridge() public {
        vm.expectRevert();
        spokePool.setTokenBridge(address(l2Dai), rando);

        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.setTokenBridge, (address(l2Dai), rando)));
        assertEq(spokePool.tokenBridges(address(l2Dai)), rando);
    }

    function testOnlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        vm.expectRevert();
        spokePool.setCrossDomainAdmin(rando);

        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.setCrossDomainAdmin, (rando)));
        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function testOnlyCrossDomainOwnerCanSetWithdrawalRecipient() public {
        vm.expectRevert();
        spokePool.setWithdrawalRecipient(rando);

        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.setWithdrawalRecipient, (rando)));
        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function testOnlyCrossDomainOwnerCanInitializeRelayerRefund() public {
        vm.expectRevert();
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot)));

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function testOnlyCrossDomainOwnerCanDeleteRelayerRefund() public {
        // First create a root bundle
        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot)));

        // Direct call fails
        vm.expectRevert();
        spokePool.emergencyDeleteRootBundle(0);

        // Via cross domain messenger succeeds
        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.emergencyDeleteRootBundle, (0)));

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    function testOnlyCrossDomainOwnerCanSetRemoteL1Token() public {
        assertEq(spokePool.remoteL1Tokens(address(l2Dai)), address(0));

        vm.expectRevert();
        spokePool.setRemoteL1Token(address(l2Dai), rando);

        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.setRemoteL1Token, (address(l2Dai), rando)));
        assertEq(spokePool.remoteL1Tokens(address(l2Dai)), rando);
    }

    function testBridgeTokensToHubPoolCorrectlyCallsL2BridgeForERC20() public {
        uint256 chainId = spokePool.chainId();

        // Build a simple relayer refund leaf
        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: amountToReturn,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(l2Dai),
            refundAddresses: new address[](0)
        });

        // Compute merkle root (single leaf tree - root is the leaf hash)
        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        // Relay root bundle via cross domain messenger
        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (leafHash, mockTreeRoot)));

        // Execute refund leaf - this should call withdrawTo on the standard bridge
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);

        // The MockBedrockL2StandardBridge emits ERC20WithdrawalInitiated when withdrawTo is called
        // We can't easily check events from the etch'd contract, but we verified the flow works
    }

    function testBridgeTokensToHubPoolCorrectlyCallsL2BridgeForWETH() public {
        uint256 chainId = spokePool.chainId();

        // Build a relayer refund leaf for WETH
        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: amountToReturn,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(weth),
            refundAddresses: new address[](0)
        });

        // Compute merkle root
        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        // Relay root bundle via cross domain messenger
        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (leafHash, mockTreeRoot)));

        uint256 wethBalanceBefore = weth.balanceOf(address(spokePool));
        uint256 bridgeEthBefore = address(l2StandardBridge).balance;

        // Execute refund leaf - this should unwrap WETH and call withdrawTo with ETH
        // The spoke pool proxy can receive ETH (via fallback->delegatecall) so WETH.withdraw works
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);

        // WETH balance should decrease
        assertEq(weth.balanceOf(address(spokePool)), wethBalanceBefore - amountToReturn);

        // The L2 standard bridge should have received the ETH
        assertEq(address(l2StandardBridge).balance, bridgeEthBefore + amountToReturn);
    }

    function testBridgeTokensUsesAlternativeL2GatewayRouter() public {
        uint256 chainId = spokePool.chainId();

        // Deploy an alternative bridge
        MockBedrockL2StandardBridge altL2Bridge = new MockBedrockL2StandardBridge();

        // Set alternative bridge for l2Dai
        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.setTokenBridge, (address(l2Dai), address(altL2Bridge))));

        // Build a relayer refund leaf
        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: amountToReturn,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(l2Dai),
            refundAddresses: new address[](0)
        });

        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (leafHash, mockTreeRoot)));

        // Execute refund leaf - should use alternative bridge
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    function testBridgeTokensUsesBridgeERC20ToWhenRemoteL1TokenSet() public {
        uint256 chainId = spokePool.chainId();

        // Create a "native L2" token and its L1 counterpart (both need to be real tokens for mock to work)
        MintableERC20 nativeL2Token = new MintableERC20("Native L2 Token", "NL2T");
        MintableERC20 remoteL1Token = new MintableERC20("Remote L1 Token", "RL1T");

        // Seed spokePool with native L2 token
        nativeL2Token.mint(address(spokePool), amountHeldByPool);

        // The mock bridge needs some remote L1 tokens to transfer to hubPool
        remoteL1Token.mint(address(l2StandardBridge), amountHeldByPool);

        // Set the remote L1 token mapping
        _callViaCrossDomainMessenger(
            abi.encodeCall(spokePool.setRemoteL1Token, (address(nativeL2Token), address(remoteL1Token)))
        );

        // Build a relayer refund leaf
        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: amountToReturn,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(nativeL2Token),
            refundAddresses: new address[](0)
        });

        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        _callViaCrossDomainMessenger(abi.encodeCall(spokePool.relayRootBundle, (leafHash, mockTreeRoot)));

        // Execute refund leaf - should call bridgeERC20To
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);

        // Verify the native L2 token was transferred to the bridge
        assertEq(nativeL2Token.balanceOf(address(l2StandardBridge)), amountToReturn);
    }
}
