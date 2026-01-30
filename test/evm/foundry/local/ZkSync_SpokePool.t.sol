// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { ZkSync_SpokePool, ZkBridgeLike, IL2ETH } from "../../../../contracts/ZkSync_SpokePool.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";
import { CrossDomainAddressUtils } from "../../../../contracts/libraries/CrossDomainAddressUtils.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock ZkSync ERC20 Bridge
contract MockZkErc20Bridge {
    event WithdrawCalled(address l1Receiver, address l2Token, uint256 amount);

    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external {
        emit WithdrawCalled(_l1Receiver, _l2Token, _amount);
    }
}

// Mock L2 ETH contract
contract MockL2Eth {
    event WithdrawCalled(address l1Receiver, uint256 value);

    function withdraw(address _l1Receiver) external payable {
        emit WithdrawCalled(_l1Receiver, msg.value);
    }
}

contract ZkSyncSpokePoolTest is Test {
    ZkSync_SpokePool public spokePool;
    MockZkErc20Bridge public zkErc20Bridge;
    MockZkErc20Bridge public zkUSDCBridge;
    MockL2Eth public l2Eth;
    WETH9 public weth;
    MintableERC20 public dai;
    MintableERC20 public usdc;

    address public owner;
    address public crossDomainAlias;
    address public hubPool;
    address public relayer;
    address public rando;

    bytes32 public mockTreeRoot;
    uint256 public amountToReturn = 1 ether;
    uint256 public amountHeldByPool = 10 ether;

    // L2 ETH address on ZkSync
    address constant L2_ETH_ADDRESS = 0x000000000000000000000000000000000000800A;

    function setUp() public {
        owner = makeAddr("owner");
        hubPool = makeAddr("hubPool");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");
        mockTreeRoot = keccak256("mockTreeRoot");

        // Compute the cross-domain alias for the owner (same algorithm as Arbitrum)
        crossDomainAlias = CrossDomainAddressUtils.applyL1ToL2Alias(owner);

        // Fund the cross-domain alias with ETH
        vm.deal(crossDomainAlias, 1 ether);

        // Deploy WETH
        weth = new WETH9();

        // Deploy tokens
        dai = new MintableERC20("DAI", "DAI");
        usdc = new MintableERC20("USDC", "USDC");

        // Deploy mock bridges
        zkErc20Bridge = new MockZkErc20Bridge();
        zkUSDCBridge = new MockZkErc20Bridge();

        // Deploy mock L2 ETH and etch it at the expected address
        l2Eth = new MockL2Eth();
        vm.etch(L2_ETH_ADDRESS, address(l2Eth).code);

        // Deploy implementation with USDC bridge (not CCTP)
        ZkSync_SpokePool implementation = new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)),
            ZkBridgeLike(address(zkUSDCBridge)),
            ITokenMessenger(address(0)), // No CCTP
            60 * 60,
            9 * 60 * 60
        );

        // Deploy proxy
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(ZkSync_SpokePool.initialize, (0, ZkBridgeLike(address(zkErc20Bridge)), owner, hubPool))
            )
        );
        spokePool = ZkSync_SpokePool(payable(proxy));

        // Seed spoke pool with tokens
        dai.mint(address(spokePool), amountHeldByPool);
        usdc.mint(address(spokePool), amountHeldByPool);

        // Give spoke pool WETH by actually depositing ETH
        vm.deal(address(spokePool), amountHeldByPool);
        vm.prank(address(spokePool));
        weth.deposit{ value: amountHeldByPool }();
    }

    function testOnlyCrossDomainOwnerUpgradeLogicContract() public {
        // Deploy new implementation
        ZkSync_SpokePool newImplementation = new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)),
            ZkBridgeLike(address(zkUSDCBridge)),
            ITokenMessenger(address(0)),
            60 * 60,
            9 * 60 * 60
        );

        // upgradeTo fails unless called by aliased cross domain admin
        vm.prank(rando);
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.upgradeTo(address(newImplementation));

        // Even owner cannot call directly (must be aliased)
        vm.prank(owner);
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.upgradeTo(address(newImplementation));

        // Cross domain alias can upgrade
        vm.prank(crossDomainAlias);
        spokePool.upgradeTo(address(newImplementation));
    }

    function testOnlyCrossDomainOwnerCanSetZkBridge() public {
        vm.prank(rando);
        vm.expectRevert();
        spokePool.setZkBridge(ZkBridgeLike(rando));

        vm.prank(crossDomainAlias);
        spokePool.setZkBridge(ZkBridgeLike(rando));
        assertEq(address(spokePool.zkErc20Bridge()), rando);
    }

    function testOnlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        vm.prank(rando);
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.setCrossDomainAdmin(rando);

        vm.prank(crossDomainAlias);
        spokePool.setCrossDomainAdmin(rando);
        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function testOnlyCrossDomainOwnerCanSetWithdrawalRecipient() public {
        vm.prank(rando);
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.setWithdrawalRecipient(rando);

        vm.prank(crossDomainAlias);
        spokePool.setWithdrawalRecipient(rando);
        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function testOnlyCrossDomainOwnerCanRelayRootBundle() public {
        vm.prank(rando);
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function testOnlyCrossDomainOwnerCanDeleteRelayerRefund() public {
        // First create a root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Direct call fails
        vm.prank(rando);
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.emergencyDeleteRootBundle(0);

        // Cross domain alias succeeds
        vm.prank(crossDomainAlias);
        spokePool.emergencyDeleteRootBundle(0);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    function testBridgeERC20CallsStandardBridge() public {
        uint256 chainId = spokePool.chainId();

        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: amountToReturn,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(dai),
            refundAddresses: new address[](0)
        });

        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Expect the WithdrawCalled event from zkErc20Bridge
        vm.expectEmit(address(zkErc20Bridge));
        emit MockZkErc20Bridge.WithdrawCalled(hubPool, address(dai), amountToReturn);

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    function testBridgeUSDCCallsCustomUSDCBridge() public {
        uint256 chainId = spokePool.chainId();

        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: amountToReturn,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(usdc),
            refundAddresses: new address[](0)
        });

        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Expect the WithdrawCalled event from zkUSDCBridge
        vm.expectEmit(address(zkUSDCBridge));
        emit MockZkErc20Bridge.WithdrawCalled(hubPool, address(usdc), amountToReturn);

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    function testBridgeWETHUnwrapsAndCallsL2Eth() public {
        uint256 chainId = spokePool.chainId();

        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: amountToReturn,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(weth),
            refundAddresses: new address[](0)
        });

        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        uint256 wethBalanceBefore = weth.balanceOf(address(spokePool));

        // Expect the WithdrawCalled event from L2 ETH
        vm.expectEmit(L2_ETH_ADDRESS);
        emit MockL2Eth.WithdrawCalled(hubPool, amountToReturn);

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);

        // WETH balance should decrease
        assertEq(weth.balanceOf(address(spokePool)), wethBalanceBefore - amountToReturn);
    }

    function testInvalidUSDCBridgeConfigBothSet() public {
        // Both zkUSDCBridge and cctpTokenMessenger set - should fail
        vm.expectRevert(ZkSync_SpokePool.InvalidBridgeConfig.selector);
        new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)),
            ZkBridgeLike(address(zkUSDCBridge)),
            ITokenMessenger(makeAddr("cctp")), // Both bridges set
            60 * 60,
            9 * 60 * 60
        );
    }

    function testInvalidUSDCBridgeConfigNeitherSet() public {
        // Neither zkUSDCBridge nor cctpTokenMessenger set when USDC is specified - should fail
        vm.expectRevert(ZkSync_SpokePool.InvalidBridgeConfig.selector);
        new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)),
            ZkBridgeLike(address(0)), // Neither bridge set
            ITokenMessenger(address(0)),
            60 * 60,
            9 * 60 * 60
        );
    }

    function testValidUSDCBridgeConfigOnlyZkBridge() public {
        // Only zkUSDCBridge set - should succeed
        ZkSync_SpokePool validSpokePool = new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)),
            ZkBridgeLike(address(zkUSDCBridge)),
            ITokenMessenger(address(0)),
            60 * 60,
            9 * 60 * 60
        );
        assertEq(address(validSpokePool.zkUSDCBridge()), address(zkUSDCBridge));
    }

    function testValidUSDCBridgeConfigOnlyCCTP() public {
        // Only cctpTokenMessenger set - should succeed
        address cctpMessenger = makeAddr("cctp");
        ZkSync_SpokePool validSpokePool = new ZkSync_SpokePool(
            address(weth),
            IERC20(address(usdc)),
            ZkBridgeLike(address(0)),
            ITokenMessenger(cctpMessenger),
            60 * 60,
            9 * 60 * 60
        );
        assertEq(address(validSpokePool.zkUSDCBridge()), address(0));
    }
}
