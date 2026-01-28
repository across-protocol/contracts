// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { PolygonZkEVM_SpokePool } from "../../../../contracts/PolygonZkEVM_SpokePool.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";
import { IPolygonZkEVMBridge } from "../../../../contracts/external/interfaces/IPolygonZkEVMBridge.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock Polygon zkEVM Bridge
contract MockPolygonZkEVMBridge {
    event BridgeAssetCalled(
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        address token,
        bool forceUpdateGlobalExitRoot,
        bytes permitData,
        uint256 value
    );

    function bridgeAsset(
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        address token,
        bool forceUpdateGlobalExitRoot,
        bytes calldata permitData
    ) external payable {
        emit BridgeAssetCalled(
            destinationNetwork,
            destinationAddress,
            amount,
            token,
            forceUpdateGlobalExitRoot,
            permitData,
            msg.value
        );
    }
}

contract PolygonZkEVMSpokePoolTest is Test {
    PolygonZkEVM_SpokePool public spokePool;
    MockPolygonZkEVMBridge public polygonZkEvmBridge;
    WETH9 public weth;
    MintableERC20 public dai;

    address public owner;
    address public hubPool;
    address public relayer;
    address public rando;

    bytes32 public mockTreeRoot;
    uint256 public amountToReturn = 1 ether;
    uint256 public amountHeldByPool = 10 ether;

    uint32 constant POLYGON_ZKEVM_L1_NETWORK_ID = 0;

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

        // Deploy mock bridge
        polygonZkEvmBridge = new MockPolygonZkEVMBridge();

        // Deploy implementation
        PolygonZkEVM_SpokePool implementation = new PolygonZkEVM_SpokePool(address(weth), 60 * 60, 9 * 60 * 60);

        // Deploy proxy
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(
                    PolygonZkEVM_SpokePool.initialize,
                    (IPolygonZkEVMBridge(address(polygonZkEvmBridge)), 0, owner, hubPool)
                )
            )
        );
        spokePool = PolygonZkEVM_SpokePool(payable(proxy));

        // Seed spoke pool with tokens
        dai.mint(address(spokePool), amountHeldByPool);

        // Give spoke pool WETH by actually depositing ETH
        vm.deal(address(spokePool), amountHeldByPool);
        vm.prank(address(spokePool));
        weth.deposit{ value: amountHeldByPool }();
    }

    // Helper to call admin functions via the bridge's onMessageReceived
    function _callAsAdmin(bytes memory fnData) internal {
        vm.prank(address(polygonZkEvmBridge));
        spokePool.onMessageReceived(owner, POLYGON_ZKEVM_L1_NETWORK_ID, fnData);
    }

    function testOnlyCrossDomainOwnerUpgradeLogicContract() public {
        // Deploy new implementation
        PolygonZkEVM_SpokePool newImplementation = new PolygonZkEVM_SpokePool(address(weth), 60 * 60, 9 * 60 * 60);
        bytes memory upgradeData = abi.encodeCall(spokePool.upgradeTo, (address(newImplementation)));

        // Reverts if called directly
        vm.prank(rando);
        vm.expectRevert(PolygonZkEVM_SpokePool.AdminCallNotValidated.selector);
        spokePool.upgradeTo(address(newImplementation));

        // Reverts if not called from bridge
        vm.prank(rando);
        vm.expectRevert(PolygonZkEVM_SpokePool.CallerNotBridge.selector);
        spokePool.onMessageReceived(owner, POLYGON_ZKEVM_L1_NETWORK_ID, upgradeData);

        // Reverts if origin sender is not crossDomainAdmin
        vm.prank(address(polygonZkEvmBridge));
        vm.expectRevert(PolygonZkEVM_SpokePool.OriginSenderNotCrossDomain.selector);
        spokePool.onMessageReceived(rando, POLYGON_ZKEVM_L1_NETWORK_ID, upgradeData);

        // Reverts if source network is not L1
        vm.prank(address(polygonZkEvmBridge));
        vm.expectRevert(PolygonZkEVM_SpokePool.SourceChainNotHubChain.selector);
        spokePool.onMessageReceived(owner, 1, upgradeData);

        // Works with correct params
        _callAsAdmin(upgradeData);
    }

    function testOnlyCrossDomainOwnerCanSetL2PolygonZkEVMBridge() public {
        bytes memory setBridgeData = abi.encodeCall(spokePool.setL2PolygonZkEVMBridge, (IPolygonZkEVMBridge(rando)));

        // Reverts if called directly
        vm.prank(rando);
        vm.expectRevert(PolygonZkEVM_SpokePool.AdminCallNotValidated.selector);
        spokePool.setL2PolygonZkEVMBridge(IPolygonZkEVMBridge(rando));

        // Reverts if not called from bridge
        vm.prank(rando);
        vm.expectRevert(PolygonZkEVM_SpokePool.CallerNotBridge.selector);
        spokePool.onMessageReceived(owner, POLYGON_ZKEVM_L1_NETWORK_ID, setBridgeData);

        // Works with correct params
        _callAsAdmin(setBridgeData);
        assertEq(address(spokePool.l2PolygonZkEVMBridge()), rando);
    }

    function testOnlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        bytes memory setAdminData = abi.encodeCall(spokePool.setCrossDomainAdmin, (rando));

        vm.prank(rando);
        vm.expectRevert(PolygonZkEVM_SpokePool.AdminCallNotValidated.selector);
        spokePool.setCrossDomainAdmin(rando);

        _callAsAdmin(setAdminData);
        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function testOnlyCrossDomainOwnerCanRelayRootBundle() public {
        bytes memory relayData = abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot));

        vm.prank(rando);
        vm.expectRevert(PolygonZkEVM_SpokePool.AdminCallNotValidated.selector);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        _callAsAdmin(relayData);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function testBridgeWETHCorrectlyCallsBridgeAssetWithETH() public {
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

        _callAsAdmin(abi.encodeCall(spokePool.relayRootBundle, (leafHash, mockTreeRoot)));

        // Expect bridgeAsset to be called with ETH (address(0)) and value
        vm.expectEmit(address(polygonZkEvmBridge));
        emit MockPolygonZkEVMBridge.BridgeAssetCalled(
            POLYGON_ZKEVM_L1_NETWORK_ID,
            hubPool,
            amountToReturn,
            address(0), // ETH is represented as address(0)
            true,
            "",
            amountToReturn
        );

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    function testBridgeERC20CorrectlyCallsBridgeAsset() public {
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

        _callAsAdmin(abi.encodeCall(spokePool.relayRootBundle, (leafHash, mockTreeRoot)));

        // Expect bridgeAsset to be called with ERC20 token
        vm.expectEmit(address(polygonZkEvmBridge));
        emit MockPolygonZkEVMBridge.BridgeAssetCalled(
            POLYGON_ZKEVM_L1_NETWORK_ID,
            hubPool,
            amountToReturn,
            address(dai),
            true,
            "",
            0
        );

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }
}
