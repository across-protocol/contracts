// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { Polygon_SpokePool } from "../../../../contracts/Polygon_SpokePool.sol";
import { PolygonTokenBridger, PolygonIERC20Upgradeable, PolygonRegistry } from "../../../../contracts/PolygonTokenBridger.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt } from "../../../../contracts/interfaces/IOFT.sol";
import { SpokePool } from "../../../../contracts/SpokePool.sol";

// Mintable ERC20 with Polygon's withdraw method (burn)
contract PolygonMintableERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

// Mock OFT Messenger for testing LayerZero OFT bridging
contract MockPolygonOftMessenger {
    address public tokenAddress;
    MessagingFee public quoteSendReturn;
    MessagingReceipt public sendReceiptReturn;
    OFTReceipt public sendOftReceiptReturn;

    event SendCalled(SendParam sendParam, MessagingFee fee, address refundAddress, uint256 value);

    function setToken(address _token) external {
        tokenAddress = _token;
    }

    function token() external view returns (address) {
        return tokenAddress;
    }

    function setQuoteSendReturn(MessagingFee memory _fee) external {
        quoteSendReturn = _fee;
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return quoteSendReturn;
    }

    function setSendReturn(MessagingReceipt memory _receipt, OFTReceipt memory _oftReceipt) external {
        sendReceiptReturn = _receipt;
        sendOftReceiptReturn = _oftReceipt;
    }

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory, OFTReceipt memory) {
        emit SendCalled(_sendParam, _fee, _refundAddress, msg.value);
        return (sendReceiptReturn, sendOftReceiptReturn);
    }
}

// Mock Polygon Registry
contract MockPolygonRegistry {
    address public predicateAddress;

    function setErc20Predicate(address _predicate) external {
        predicateAddress = _predicate;
    }

    function erc20Predicate() external view returns (address) {
        return predicateAddress;
    }
}

// Mock Polygon ERC20 Predicate
contract MockPolygonERC20Predicate {
    event StartExitCalled(bytes data);

    function startExitWithBurntTokens(bytes calldata data) external {
        emit StartExitCalled(data);
    }
}

// Mock contract caller for testing NotEOA revert
contract MockSpokePoolCaller {
    constructor(
        Polygon_SpokePool spokePool,
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory leaf,
        bytes32[] memory proof
    ) {
        spokePool.executeRelayerRefundLeaf(rootBundleId, leaf, proof);
    }
}

contract PolygonSpokePoolTest is Test {
    Polygon_SpokePool public spokePool;
    PolygonTokenBridger public polygonTokenBridger;
    MockPolygonRegistry public polygonRegistry;
    MockPolygonERC20Predicate public erc20Predicate;
    MockPolygonOftMessenger public l2OftMessenger;
    WETH9 public weth;
    PolygonMintableERC20 public dai;
    PolygonMintableERC20 public l2Usdt;

    address public owner;
    address public hubPool;
    address public relayer;
    address public rando;
    address public fxChild;

    bytes32 public mockTreeRoot;
    uint256 public amountToReturn = 1 ether;
    uint256 public amountHeldByPool = 10 ether;

    // L1 and L2 chain IDs for token bridger
    uint256 constant L1_CHAIN_ID = 1;
    uint256 constant L2_CHAIN_ID = 31337; // Default foundry chain ID

    // OFT constants
    uint32 constant OFT_HUB_EID = 30101; // Mainnet EID for LayerZero
    uint256 constant OFT_FEE_CAP = 1 ether;

    function setUp() public {
        owner = makeAddr("owner");
        hubPool = makeAddr("hubPool");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");
        fxChild = makeAddr("fxChild");
        mockTreeRoot = keccak256("mockTreeRoot");

        // Fund fxChild with ETH for calls
        vm.deal(fxChild, 1 ether);

        // Fund relayer with ETH for OFT fees
        vm.deal(relayer, 10 ether);

        // Deploy WETH
        weth = new WETH9();

        // Deploy tokens
        dai = new PolygonMintableERC20("DAI", "DAI");
        l2Usdt = new PolygonMintableERC20("L2 USDT", "L2USDT");

        // Deploy OFT messenger mock
        l2OftMessenger = new MockPolygonOftMessenger();
        l2OftMessenger.setToken(address(l2Usdt));

        // Deploy mock registry and predicate
        polygonRegistry = new MockPolygonRegistry();
        erc20Predicate = new MockPolygonERC20Predicate();
        polygonRegistry.setErc20Predicate(address(erc20Predicate));

        // Deploy PolygonTokenBridger (configured for L2)
        polygonTokenBridger = new PolygonTokenBridger(
            hubPool,
            PolygonRegistry(address(polygonRegistry)),
            WETH9Interface(address(weth)),
            address(weth),
            L1_CHAIN_ID,
            L2_CHAIN_ID
        );

        // Deploy implementation with OFT support
        Polygon_SpokePool implementation = new Polygon_SpokePool(
            address(weth),
            60 * 60,
            9 * 60 * 60,
            IERC20(address(0)), // l2Usdc
            ITokenMessenger(address(0)), // cctpTokenMessenger
            OFT_HUB_EID,
            OFT_FEE_CAP
        );

        // Deploy proxy
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(Polygon_SpokePool.initialize, (0, polygonTokenBridger, owner, hubPool, fxChild))
            )
        );
        spokePool = Polygon_SpokePool(payable(proxy));

        // Seed spoke pool with tokens
        dai.mint(address(spokePool), amountHeldByPool);
        l2Usdt.mint(address(spokePool), amountHeldByPool);

        // Give spoke pool WETH by actually depositing ETH
        vm.deal(address(spokePool), amountHeldByPool);
        vm.prank(address(spokePool));
        weth.deposit{ value: amountHeldByPool }();
    }

    // Helper to call admin functions via fxChild's processMessageFromRoot
    function _callAsAdmin(bytes memory data) internal {
        vm.prank(fxChild);
        spokePool.processMessageFromRoot(0, owner, data);
    }

    function testOnlyCrossDomainOwnerUpgradeLogicContract() public {
        // Deploy new implementation
        Polygon_SpokePool newImplementation = new Polygon_SpokePool(
            address(weth),
            60 * 60,
            9 * 60 * 60,
            IERC20(address(0)),
            ITokenMessenger(address(0)),
            0,
            0
        );

        bytes memory upgradeData = abi.encodeCall(spokePool.upgradeTo, (address(newImplementation)));

        // Reverts if wrong rootMessageSender address
        vm.prank(fxChild);
        vm.expectRevert(Polygon_SpokePool.NotHubPool.selector);
        spokePool.processMessageFromRoot(0, rando, upgradeData);

        // Reverts if wrong calling address (not fxChild)
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.NotFxChild.selector);
        spokePool.processMessageFromRoot(0, owner, upgradeData);

        // Works with correct params
        _callAsAdmin(upgradeData);
    }

    function testOnlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        bytes memory setCrossDomainAdminData = abi.encodeCall(spokePool.setCrossDomainAdmin, (rando));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.CallValidatedNotSet.selector);
        spokePool.setCrossDomainAdmin(rando);

        // Reverts if wrong rootMessageSender
        vm.prank(fxChild);
        vm.expectRevert(Polygon_SpokePool.NotHubPool.selector);
        spokePool.processMessageFromRoot(0, rando, setCrossDomainAdminData);

        // Reverts if wrong caller
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.NotFxChild.selector);
        spokePool.processMessageFromRoot(0, owner, setCrossDomainAdminData);

        // Works with correct params
        _callAsAdmin(setCrossDomainAdminData);
        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function testOnlyCrossDomainOwnerCanSetWithdrawalRecipient() public {
        bytes memory setWithdrawalRecipientData = abi.encodeCall(spokePool.setWithdrawalRecipient, (rando));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.CallValidatedNotSet.selector);
        spokePool.setWithdrawalRecipient(rando);

        // Reverts if wrong rootMessageSender
        vm.prank(fxChild);
        vm.expectRevert(Polygon_SpokePool.NotHubPool.selector);
        spokePool.processMessageFromRoot(0, rando, setWithdrawalRecipientData);

        // Reverts if wrong caller
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.NotFxChild.selector);
        spokePool.processMessageFromRoot(0, owner, setWithdrawalRecipientData);

        // Works with correct params
        _callAsAdmin(setWithdrawalRecipientData);
        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function testOnlyCrossDomainOwnerCanRelayRootBundle() public {
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.CallValidatedNotSet.selector);
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Reverts if wrong rootMessageSender
        vm.prank(fxChild);
        vm.expectRevert(Polygon_SpokePool.NotHubPool.selector);
        spokePool.processMessageFromRoot(0, rando, relayRootBundleData);

        // Reverts if wrong caller
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.NotFxChild.selector);
        spokePool.processMessageFromRoot(0, owner, relayRootBundleData);

        // Works with correct params
        _callAsAdmin(relayRootBundleData);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function testCannotReenterProcessMessageFromRoot() public {
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot));
        bytes memory nestedData = abi.encodeCall(spokePool.processMessageFromRoot, (0, owner, relayRootBundleData));

        // Should revert when trying to re-enter processMessageFromRoot
        // The inner CallValidatedAlreadySet error gets wrapped into DelegateCallFailed
        vm.prank(fxChild);
        vm.expectRevert(Polygon_SpokePool.DelegateCallFailed.selector);
        spokePool.processMessageFromRoot(0, owner, nestedData);
    }

    function testOnlyCrossDomainOwnerCanDeleteRelayerRefund() public {
        // First create a root bundle
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot));
        _callAsAdmin(relayRootBundleData);

        bytes memory emergencyDeleteData = abi.encodeCall(spokePool.emergencyDeleteRootBundle, (0));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.CallValidatedNotSet.selector);
        spokePool.emergencyDeleteRootBundle(0);

        // Reverts if wrong rootMessageSender
        vm.prank(fxChild);
        vm.expectRevert(Polygon_SpokePool.NotHubPool.selector);
        spokePool.processMessageFromRoot(0, rando, emergencyDeleteData);

        // Reverts if wrong caller
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.NotFxChild.selector);
        spokePool.processMessageFromRoot(0, owner, emergencyDeleteData);

        // Works with correct params
        _callAsAdmin(emergencyDeleteData);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    function testOnlyCrossDomainOwnerCanSetFxChild() public {
        bytes memory setFxChildData = abi.encodeCall(spokePool.setFxChild, (rando));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.CallValidatedNotSet.selector);
        spokePool.setFxChild(rando);

        // Works with correct params
        _callAsAdmin(setFxChildData);
        assertEq(spokePool.fxChild(), rando);
    }

    function testOnlyCrossDomainOwnerCanSetPolygonTokenBridger() public {
        bytes memory setPolygonTokenBridgerData = abi.encodeCall(spokePool.setPolygonTokenBridger, (payable(rando)));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert(Polygon_SpokePool.CallValidatedNotSet.selector);
        spokePool.setPolygonTokenBridger(payable(rando));

        // Works with correct params
        _callAsAdmin(setPolygonTokenBridgerData);
        assertEq(address(spokePool.polygonTokenBridger()), rando);
    }

    function testCanWrapNativeToken() public {
        // Send native MATIC to spoke pool
        uint256 nativeAmount = 0.1 ether;
        vm.deal(rando, nativeAmount);
        vm.prank(rando);
        (bool success, ) = address(spokePool).call{ value: nativeAmount }("");
        require(success, "Transfer failed");

        uint256 wethBalanceBefore = weth.balanceOf(address(spokePool));

        // Call wrap
        spokePool.wrap();

        // WETH balance should increase
        assertEq(weth.balanceOf(address(spokePool)), wethBalanceBefore + nativeAmount);
    }

    function testBridgeTokensThroughPolygonTokenBridger() public {
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

        uint256 daiBalanceBefore = dai.balanceOf(address(spokePool));

        // Execute refund leaf - DAI should be sent to bridger which burns it
        // Use vm.prank with both msg.sender and tx.origin to satisfy EOA check
        vm.prank(relayer, relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);

        // The token bridger's send() is called, which burns the tokens
        // Spoke pool's DAI balance should decrease by amountToReturn
        assertEq(dai.balanceOf(address(spokePool)), daiBalanceBefore - amountToReturn);
    }

    function testMustBeEOAToExecuteRefundLeafWithAmountToReturn() public {
        uint256 chainId = spokePool.chainId();

        // Leaf with amountToReturn > 0
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

        // Deploying mock caller tries to execute leaf from within constructor - should fail
        vm.expectRevert(abi.encodeWithSignature("NotEOA()"));
        new MockSpokePoolCaller(spokePool, 0, leaf, proof);
    }

    function testContractCanExecuteRefundLeafWithZeroAmountToReturn() public {
        uint256 chainId = spokePool.chainId();

        // Leaf with amountToReturn == 0
        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: 0,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(dai),
            refundAddresses: new address[](0)
        });

        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        _callAsAdmin(abi.encodeCall(spokePool.relayRootBundle, (leafHash, mockTreeRoot)));

        // Contract caller should succeed when amountToReturn == 0
        new MockSpokePoolCaller(spokePool, 0, leaf, proof);
    }

    function testCannotUseNestedMulticalls() public {
        uint256 chainId = spokePool.chainId();

        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: 0,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(dai),
            refundAddresses: new address[](0)
        });

        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        _callAsAdmin(abi.encodeCall(spokePool.relayRootBundle, (leafHash, mockTreeRoot)));

        // Create nested multicall data
        bytes[] memory innerData = new bytes[](1);
        innerData[0] = abi.encodeCall(spokePool.executeRelayerRefundLeaf, (0, leaf, proof));

        bytes[] memory outerData = new bytes[](1);
        outerData[0] = abi.encodeCall(spokePool.multicall, (innerData));

        // Nested multicalls should revert
        vm.prank(relayer);
        vm.expectRevert(Polygon_SpokePool.MulticallExecuteLeaf.selector);
        spokePool.multicall(outerData);
    }

    // ============ OFT Tests ============

    function testBridgeTokensUsingOftMessengerForL2Usdt() public {
        // Set up OFT messenger for L2 USDT via cross-domain call
        bytes memory setOftMessengerData = abi.encodeCall(
            spokePool.setOftMessenger,
            (address(l2Usdt), address(l2OftMessenger))
        );
        _callAsAdmin(setOftMessengerData);

        uint256 l2UsdtSendAmount = 1 ether;
        uint256 chainId = spokePool.chainId();

        // Build a relayer refund leaf for L2 USDT
        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: l2UsdtSendAmount,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(l2Usdt),
            refundAddresses: new address[](0)
        });

        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        _callAsAdmin(abi.encodeCall(spokePool.relayRootBundle, (leafHash, mockTreeRoot)));

        // Set up quoteSend return value (no fees for simplicity)
        MessagingFee memory msgFee = MessagingFee({ nativeFee: 0, lzTokenFee: 0 });
        l2OftMessenger.setQuoteSendReturn(msgFee);

        // Set up send return values
        MessagingReceipt memory msgReceipt = MessagingReceipt({ guid: keccak256("test-guid"), nonce: 1, fee: msgFee });
        OFTReceipt memory oftReceipt = OFTReceipt({
            amountSentLD: l2UsdtSendAmount,
            amountReceivedLD: l2UsdtSendAmount
        });
        l2OftMessenger.setSendReturn(msgReceipt, oftReceipt);

        // Execute refund leaf - use vm.prank with both msg.sender and tx.origin to satisfy EOA check
        vm.prank(relayer, relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);

        // Verify spoke pool approved OFT messenger to spend its L2 USDT
        assertEq(l2Usdt.allowance(address(spokePool), address(l2OftMessenger)), l2UsdtSendAmount);
    }

    function testOftRevertsWithOftFeeUnderpaid() public {
        // Set up OFT messenger for L2 USDT via cross-domain call
        bytes memory setOftMessengerData = abi.encodeCall(
            spokePool.setOftMessenger,
            (address(l2Usdt), address(l2OftMessenger))
        );
        _callAsAdmin(setOftMessengerData);

        uint256 l2UsdtSendAmount = 1 ether;
        uint256 chainId = spokePool.chainId();

        SpokePoolInterface.RelayerRefundLeaf memory leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: l2UsdtSendAmount,
            chainId: chainId,
            refundAmounts: new uint256[](0),
            leafId: 0,
            l2TokenAddress: address(l2Usdt),
            refundAddresses: new address[](0)
        });

        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        _callAsAdmin(abi.encodeCall(spokePool.relayRootBundle, (leafHash, mockTreeRoot)));

        // Set up quoteSend with required fee but don't send any ETH
        uint256 nativeFee = 0.1 ether;
        MessagingFee memory msgFee = MessagingFee({ nativeFee: nativeFee, lzTokenFee: 0 });
        l2OftMessenger.setQuoteSendReturn(msgFee);

        // Execute refund leaf without value - should revert
        // Use vm.prank with both msg.sender and tx.origin to satisfy EOA check
        vm.prank(relayer, relayer);
        vm.expectRevert(SpokePool.OFTFeeUnderpaid.selector);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof); // No value sent
    }
}
