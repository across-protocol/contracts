// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { Ethereum_SpokePool } from "../../../../contracts/Ethereum_SpokePool.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";

contract EthereumSpokePoolTest is Test {
    Ethereum_SpokePool public spokePool;
    WETH9 public weth;
    ERC20 public dai;

    address public owner;
    address public hubPool;
    address public relayer;
    address public rando;

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

        // Deploy a simple ERC20 for DAI
        dai = new ERC20("DAI", "DAI");

        // Deploy implementation
        Ethereum_SpokePool implementation = new Ethereum_SpokePool(address(weth), 60 * 60, 9 * 60 * 60);

        // Deploy proxy
        vm.prank(owner);
        address proxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeCall(Ethereum_SpokePool.initialize, (0, hubPool)))
        );
        spokePool = Ethereum_SpokePool(payable(proxy));

        // Seed spoke pool with tokens
        deal(address(dai), address(spokePool), amountHeldByPool);
        deal(address(weth), address(spokePool), amountHeldByPool);
    }

    function testOnlyCrossDomainOwnerUpgradeLogicContract() public {
        // Deploy new implementation
        Ethereum_SpokePool newImplementation = new Ethereum_SpokePool(address(weth), 60 * 60, 9 * 60 * 60);

        // upgradeTo fails unless called by owner
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.upgradeTo(address(newImplementation));

        // Owner can upgrade
        vm.prank(owner);
        spokePool.upgradeTo(address(newImplementation));
    }

    function testOnlyOwnerCanSetCrossDomainAdmin() public {
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.setCrossDomainAdmin(rando);

        vm.prank(owner);
        spokePool.setCrossDomainAdmin(rando);
        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function testOnlyOwnerCanSetWithdrawalRecipient() public {
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.setWithdrawalRecipient(rando);

        vm.prank(owner);
        spokePool.setWithdrawalRecipient(rando);
        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function testOnlyOwnerCanInitializeRelayerRefund() public {
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        vm.prank(owner);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function testOnlyOwnerCanDeleteRelayerRefund() public {
        // First create a root bundle
        vm.prank(owner);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Rando cannot delete
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.emergencyDeleteRootBundle(0);

        // Owner can delete
        vm.prank(owner);
        spokePool.emergencyDeleteRootBundle(0);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    function testBridgeTokensToHubPoolCorrectlySendsTokens() public {
        uint256 chainId = cycleChainId();

        // Build a simple relayer refund leaf
        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: amountToReturn,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(dai),
            refundAddresses: new address[](0)
        });

        // Compute merkle root (single leaf tree - root is the leaf hash)
        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        // Relay root bundle
        vm.prank(owner);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Get initial balances
        uint256 spokePoolBalanceBefore = dai.balanceOf(address(spokePool));
        uint256 hubPoolBalanceBefore = dai.balanceOf(hubPool);

        // Execute refund leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);

        // Check balances changed correctly
        assertEq(dai.balanceOf(address(spokePool)), spokePoolBalanceBefore - amountToReturn);
        assertEq(dai.balanceOf(hubPool), hubPoolBalanceBefore + amountToReturn);
    }

    // Helper to get chainId since spokePool.chainId() returns block.chainid
    function cycleChainId() internal view returns (uint256) {
        return spokePool.chainId();
    }
}
