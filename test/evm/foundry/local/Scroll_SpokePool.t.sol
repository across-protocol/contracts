// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { Scroll_SpokePool, IL2GatewayRouterExtended } from "../../../../contracts/Scroll_SpokePool.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";
import { IScrollMessenger } from "@scroll-tech/contracts/libraries/IScrollMessenger.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock Scroll Gateway Router
contract MockScrollGatewayRouter {
    address public defaultGateway;

    event WithdrawERC20Called(address token, address to, uint256 amount, uint256 gasLimit);

    function setDefaultGateway(address _gateway) external {
        defaultGateway = _gateway;
    }

    function defaultERC20Gateway() external view returns (address) {
        return defaultGateway;
    }

    function getERC20Gateway(address) external view returns (address) {
        return defaultGateway;
    }

    function withdrawERC20(address _token, address _to, uint256 _amount, uint256 _gasLimit) external payable {
        emit WithdrawERC20Called(_token, _to, _amount, _gasLimit);
    }
}

// Mock Scroll Messenger
contract MockScrollMessenger {
    address private _xDomainSender;

    function setXDomainMessageSender(address sender) external {
        _xDomainSender = sender;
    }

    function xDomainMessageSender() external view returns (address) {
        return _xDomainSender;
    }
}

contract ScrollSpokePoolTest is Test {
    Scroll_SpokePool public spokePool;
    MockScrollGatewayRouter public l2GatewayRouter;
    MockScrollMessenger public l2Messenger;
    WETH9 public weth;
    MintableERC20 public dai;

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

        // Deploy tokens
        dai = new MintableERC20("DAI", "DAI");

        // Deploy mocks
        l2GatewayRouter = new MockScrollGatewayRouter();
        l2Messenger = new MockScrollMessenger();

        // Set default gateway to itself for simplicity
        l2GatewayRouter.setDefaultGateway(address(l2GatewayRouter));

        // Deploy implementation
        Scroll_SpokePool implementation = new Scroll_SpokePool(address(weth), 60 * 60, 9 * 60 * 60);

        // Deploy proxy
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(
                    Scroll_SpokePool.initialize,
                    (
                        IL2GatewayRouterExtended(address(l2GatewayRouter)),
                        IScrollMessenger(address(l2Messenger)),
                        0,
                        owner,
                        hubPool
                    )
                )
            )
        );
        spokePool = Scroll_SpokePool(payable(proxy));

        // Seed spoke pool with tokens
        dai.mint(address(spokePool), amountHeldByPool);

        // Give spoke pool WETH
        vm.deal(address(spokePool), amountHeldByPool);
        vm.prank(address(spokePool));
        weth.deposit{ value: amountHeldByPool }();
    }

    // Helper to make calls as the cross-domain admin
    function _asAdmin() internal {
        l2Messenger.setXDomainMessageSender(owner);
        vm.prank(owner);
    }

    function testOnlyCrossDomainOwnerUpgradeLogicContract() public {
        // Deploy new implementation
        Scroll_SpokePool newImplementation = new Scroll_SpokePool(address(weth), 60 * 60, 9 * 60 * 60);

        // upgradeTo fails unless xDomainMessageSender is crossDomainAdmin
        vm.prank(rando);
        vm.expectRevert("Sender must be admin");
        spokePool.upgradeTo(address(newImplementation));

        // Set xDomainMessageSender to owner and call from owner
        l2Messenger.setXDomainMessageSender(owner);
        vm.prank(owner);
        spokePool.upgradeTo(address(newImplementation));
    }

    function testOnlyCrossDomainOwnerCanSetL2GatewayRouter() public {
        address newRouter = makeAddr("newRouter");

        vm.prank(rando);
        vm.expectRevert("Sender must be admin");
        spokePool.setL2GatewayRouter(IL2GatewayRouterExtended(newRouter));

        _asAdmin();
        spokePool.setL2GatewayRouter(IL2GatewayRouterExtended(newRouter));
        assertEq(address(spokePool.l2GatewayRouter()), newRouter);
    }

    function testOnlyCrossDomainOwnerCanSetL2ScrollMessenger() public {
        address newMessenger = makeAddr("newMessenger");

        vm.prank(rando);
        vm.expectRevert("Sender must be admin");
        spokePool.setL2ScrollMessenger(IScrollMessenger(newMessenger));

        _asAdmin();
        spokePool.setL2ScrollMessenger(IScrollMessenger(newMessenger));
        assertEq(address(spokePool.l2ScrollMessenger()), newMessenger);
    }

    function testOnlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        vm.prank(rando);
        vm.expectRevert("Sender must be admin");
        spokePool.setCrossDomainAdmin(rando);

        _asAdmin();
        spokePool.setCrossDomainAdmin(rando);
        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function testOnlyCrossDomainOwnerCanSetWithdrawalRecipient() public {
        vm.prank(rando);
        vm.expectRevert("Sender must be admin");
        spokePool.setWithdrawalRecipient(rando);

        _asAdmin();
        spokePool.setWithdrawalRecipient(rando);
        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function testOnlyCrossDomainOwnerCanRelayRootBundle() public {
        vm.prank(rando);
        vm.expectRevert("Sender must be admin");
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        _asAdmin();
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function testOnlyCrossDomainOwnerCanDeleteRelayerRefund() public {
        // First create a root bundle
        _asAdmin();
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Reset messenger state
        l2Messenger.setXDomainMessageSender(address(0));

        // Direct call fails
        vm.prank(rando);
        vm.expectRevert("Sender must be admin");
        spokePool.emergencyDeleteRootBundle(0);

        // Cross domain admin succeeds
        _asAdmin();
        spokePool.emergencyDeleteRootBundle(0);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    function testBridgeTokensCorrectlyCallsL2GatewayRouter() public {
        uint256 chainId = spokePool.chainId();

        // Build a simple relayer refund leaf
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

        // Relay root bundle as admin
        _asAdmin();
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Reset messenger state (any relayer can execute)
        l2Messenger.setXDomainMessageSender(address(0));

        // Execute refund leaf - expect the WithdrawERC20Called event
        vm.expectEmit(address(l2GatewayRouter));
        emit MockScrollGatewayRouter.WithdrawERC20Called(address(dai), hubPool, amountToReturn, 0);

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    function testBridgeWETHCorrectlyCallsL2GatewayRouter() public {
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

        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        // Relay root bundle as admin
        _asAdmin();
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Reset messenger state
        l2Messenger.setXDomainMessageSender(address(0));

        // Execute refund leaf - WETH also goes through withdrawERC20 on Scroll
        vm.expectEmit(address(l2GatewayRouter));
        emit MockScrollGatewayRouter.WithdrawERC20Called(address(weth), hubPool, amountToReturn, 0);

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }
}
