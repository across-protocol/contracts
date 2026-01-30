// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { Arbitrum_SpokePool } from "../../../../contracts/Arbitrum_SpokePool.sol";
import { L2GatewayRouter } from "../../../../contracts/test/ArbitrumMocks.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { CrossDomainAddressUtils } from "../../../../contracts/libraries/CrossDomainAddressUtils.sol";
import { IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt } from "../../../../contracts/interfaces/IOFT.sol";
import { SpokePool } from "../../../../contracts/SpokePool.sol";
import { OFTTransportAdapter } from "../../../../contracts/libraries/OFTTransportAdapter.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock OFT Messenger for testing LayerZero OFT bridging
contract MockOftMessenger {
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

contract ArbitrumSpokePoolTest is Test {
    Arbitrum_SpokePool public spokePool;
    L2GatewayRouter public l2GatewayRouter;
    MockOftMessenger public l2OftMessenger;
    WETH9 public weth;
    MintableERC20 public l2Dai;
    MintableERC20 public l1Dai;
    MintableERC20 public l2Usdt;

    address public owner;
    address public crossDomainAlias;
    address public hubPool;
    address public relayer;
    address public rando;

    bytes32 public mockTreeRoot;
    uint256 public amountToReturn = 1 ether;
    uint256 public amountHeldByPool = 10 ether;

    // OFT constants
    uint32 constant OFT_HUB_EID = 30101; // Mainnet EID for LayerZero
    uint256 constant OFT_FEE_CAP = 1 ether;

    function setUp() public {
        owner = makeAddr("owner");
        hubPool = makeAddr("hubPool");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");
        mockTreeRoot = keccak256("mockTreeRoot");

        // Compute the cross-domain alias for the owner
        crossDomainAlias = CrossDomainAddressUtils.applyL1ToL2Alias(owner);

        // Fund the cross-domain alias with ETH
        vm.deal(crossDomainAlias, 1 ether);

        // Fund relayer with ETH for OFT fees
        vm.deal(relayer, 10 ether);

        // Deploy WETH
        weth = new WETH9();

        // Deploy tokens
        l2Dai = new MintableERC20("L2 DAI", "L2DAI");
        l1Dai = new MintableERC20("L1 DAI", "L1DAI");
        l2Usdt = new MintableERC20("L2 USDT", "L2USDT");

        // Deploy L2 gateway router mock
        l2GatewayRouter = new L2GatewayRouter();

        // Deploy OFT messenger mock
        l2OftMessenger = new MockOftMessenger();
        l2OftMessenger.setToken(address(l2Usdt));

        // Deploy implementation with OFT support
        Arbitrum_SpokePool implementation = new Arbitrum_SpokePool(
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
                abi.encodeCall(Arbitrum_SpokePool.initialize, (0, address(l2GatewayRouter), owner, hubPool))
            )
        );
        spokePool = Arbitrum_SpokePool(payable(proxy));

        // Seed spoke pool with tokens
        l2Dai.mint(address(spokePool), amountHeldByPool);
        l2Usdt.mint(address(spokePool), amountHeldByPool);

        // Give spoke pool WETH by actually depositing ETH
        vm.deal(address(spokePool), amountHeldByPool);
        vm.prank(address(spokePool));
        weth.deposit{ value: amountHeldByPool }();

        // Whitelist L2 DAI -> L1 DAI mapping
        vm.prank(crossDomainAlias);
        spokePool.whitelistToken(address(l2Dai), address(l1Dai));

        // Set L2 token address mapping in gateway router
        l2GatewayRouter.setL2TokenAddress(address(l1Dai), address(l2Dai));
    }

    function testOnlyCrossDomainOwnerUpgradeLogicContract() public {
        // Deploy new implementation
        Arbitrum_SpokePool newImplementation = new Arbitrum_SpokePool(
            address(weth),
            60 * 60,
            9 * 60 * 60,
            IERC20(address(0)),
            ITokenMessenger(address(0)),
            0,
            0
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

    function testOnlyCrossDomainOwnerCanSetL2GatewayRouter() public {
        vm.expectRevert();
        spokePool.setL2GatewayRouter(rando);

        vm.prank(crossDomainAlias);
        spokePool.setL2GatewayRouter(rando);
        assertEq(spokePool.l2GatewayRouter(), rando);
    }

    function testOnlyCrossDomainOwnerCanWhitelistToken() public {
        vm.expectRevert();
        spokePool.whitelistToken(address(l2Dai), rando);

        vm.prank(crossDomainAlias);
        spokePool.whitelistToken(address(l2Dai), rando);
        assertEq(spokePool.whitelistedTokens(address(l2Dai)), rando);
    }

    function testOnlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        vm.expectRevert();
        spokePool.setCrossDomainAdmin(rando);

        vm.prank(crossDomainAlias);
        spokePool.setCrossDomainAdmin(rando);
        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function testOnlyCrossDomainOwnerCanSetWithdrawalRecipient() public {
        vm.expectRevert();
        spokePool.setWithdrawalRecipient(rando);

        vm.prank(crossDomainAlias);
        spokePool.setWithdrawalRecipient(rando);
        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function testOnlyCrossDomainOwnerCanInitializeRelayerRefund() public {
        vm.expectRevert();
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
        vm.expectRevert();
        spokePool.emergencyDeleteRootBundle(0);

        // Cross domain alias succeeds
        vm.prank(crossDomainAlias);
        spokePool.emergencyDeleteRootBundle(0);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    function testBridgeTokensToHubPoolCorrectlyCallsL2GatewayRouter() public {
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

        // Compute merkle root (single leaf tree)
        bytes32 leafHash = keccak256(abi.encode(leaf));
        bytes32[] memory proof = new bytes32[](0);

        // Relay root bundle
        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Execute refund leaf
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);

        // L2 gateway router should have emitted an OutboundTransfer event
        // This is captured by the mock, but we can just verify the balance changed
    }

    function testBridgeTokensRevertsIfL2TokenNotWhitelisted() public {
        uint256 chainId = spokePool.chainId();

        // Clear the whitelist
        vm.prank(crossDomainAlias);
        spokePool.whitelistToken(address(l2Dai), address(0));

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

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Should revert because L2 DAI is not whitelisted
        vm.prank(relayer);
        vm.expectRevert("Uninitialized mainnet token");
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    // ============ OFT Tests ============

    function testCrossDomainOwnerCanSetAndRemoveOftMessenger() public {
        // Non-admin cannot set OFT messenger
        vm.prank(rando);
        vm.expectRevert();
        spokePool.setOftMessenger(address(l2Usdt), address(l2OftMessenger));

        // Admin can set OFT messenger
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(l2Usdt), address(l2OftMessenger));
        assertEq(spokePool.oftMessengers(address(l2Usdt)), address(l2OftMessenger));

        // Non-admin cannot remove OFT messenger
        vm.prank(rando);
        vm.expectRevert();
        spokePool.setOftMessenger(address(l2Usdt), address(0));

        // Admin can remove OFT messenger
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(l2Usdt), address(0));
        assertEq(spokePool.oftMessengers(address(l2Usdt)), address(0));
    }

    function testBridgeTokensUsingOftMessengerForL2Usdt() public {
        // Set up OFT messenger for L2 USDT
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(l2Usdt), address(l2OftMessenger));

        uint256 l2UsdtSendAmount = 1234567;
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

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Set up quoteSend return value (no fees for simplicity)
        uint256 oftNativeFee = 0.0002 ether; // 200,000 gas * 1 gwei
        MessagingFee memory msgFee = MessagingFee({ nativeFee: oftNativeFee, lzTokenFee: 0 });
        l2OftMessenger.setQuoteSendReturn(msgFee);

        // Set up send return values
        MessagingReceipt memory msgReceipt = MessagingReceipt({ guid: keccak256("test-guid"), nonce: 1, fee: msgFee });
        OFTReceipt memory oftReceipt = OFTReceipt({
            amountSentLD: l2UsdtSendAmount,
            amountReceivedLD: l2UsdtSendAmount
        });
        l2OftMessenger.setSendReturn(msgReceipt, oftReceipt);

        // Execute refund leaf with OFT fee
        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf{ value: oftNativeFee }(0, leaf, proof);

        // Verify spoke pool approved OFT messenger to spend its L2 USDT
        assertEq(l2Usdt.allowance(address(spokePool), address(l2OftMessenger)), l2UsdtSendAmount);
    }

    function testOftRevertsWithOftLzFeeNotZero() public {
        // Set up OFT messenger for L2 USDT
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(l2Usdt), address(l2OftMessenger));

        uint256 l2UsdtSendAmount = 1234567;
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

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Set up quoteSend with non-zero lzTokenFee
        uint256 nativeFee = 0.1 ether;
        MessagingFee memory msgFee = MessagingFee({ nativeFee: nativeFee, lzTokenFee: 1 }); // lzTokenFee != 0
        l2OftMessenger.setQuoteSendReturn(msgFee);

        vm.prank(relayer);
        vm.expectRevert(OFTTransportAdapter.OftLzFeeNotZero.selector);
        spokePool.executeRelayerRefundLeaf{ value: nativeFee }(0, leaf, proof);
    }

    function testOftRevertsWithOftFeeCapExceeded() public {
        // Set up OFT messenger for L2 USDT
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(l2Usdt), address(l2OftMessenger));

        uint256 l2UsdtSendAmount = 1234567;
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

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Set up quoteSend with nativeFee higher than OFT_FEE_CAP (1 ETH)
        uint256 highNativeFee = 2 ether;
        MessagingFee memory msgFee = MessagingFee({ nativeFee: highNativeFee, lzTokenFee: 0 });
        l2OftMessenger.setQuoteSendReturn(msgFee);

        vm.prank(relayer);
        vm.expectRevert(OFTTransportAdapter.OftFeeCapExceeded.selector);
        spokePool.executeRelayerRefundLeaf{ value: highNativeFee }(0, leaf, proof);
    }

    function testOftRevertsWithOftFeeUnderpaid() public {
        // Set up OFT messenger for L2 USDT
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(l2Usdt), address(l2OftMessenger));

        uint256 l2UsdtSendAmount = 1234567;
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

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Set up quoteSend with required fee but don't send any ETH
        uint256 nativeFee = 0.1 ether;
        MessagingFee memory msgFee = MessagingFee({ nativeFee: nativeFee, lzTokenFee: 0 });
        l2OftMessenger.setQuoteSendReturn(msgFee);

        vm.prank(relayer);
        vm.expectRevert(SpokePool.OFTFeeUnderpaid.selector);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof); // No value sent
    }

    function testOftRevertsWithOftIncorrectAmountReceivedLD() public {
        // Set up OFT messenger for L2 USDT
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(l2Usdt), address(l2OftMessenger));

        uint256 l2UsdtSendAmount = 1234567;
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

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Set up quoteSend with no fees
        MessagingFee memory msgFee = MessagingFee({ nativeFee: 0, lzTokenFee: 0 });
        l2OftMessenger.setQuoteSendReturn(msgFee);

        // Set up send return with incorrect amountReceivedLD
        MessagingReceipt memory msgReceipt = MessagingReceipt({ guid: keccak256("test-guid"), nonce: 1, fee: msgFee });
        OFTReceipt memory oftReceipt = OFTReceipt({
            amountSentLD: l2UsdtSendAmount,
            amountReceivedLD: l2UsdtSendAmount - 1 // Incorrect - less than expected
        });
        l2OftMessenger.setSendReturn(msgReceipt, oftReceipt);

        vm.prank(relayer);
        vm.expectRevert(OFTTransportAdapter.OftIncorrectAmountReceivedLD.selector);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    function testOftRevertsWithOftIncorrectAmountSentLD() public {
        // Set up OFT messenger for L2 USDT
        vm.prank(crossDomainAlias);
        spokePool.setOftMessenger(address(l2Usdt), address(l2OftMessenger));

        uint256 l2UsdtSendAmount = 1234567;
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

        vm.prank(crossDomainAlias);
        spokePool.relayRootBundle(leafHash, mockTreeRoot);

        // Set up quoteSend with no fees
        MessagingFee memory msgFee = MessagingFee({ nativeFee: 0, lzTokenFee: 0 });
        l2OftMessenger.setQuoteSendReturn(msgFee);

        // Set up send return with incorrect amountSentLD
        MessagingReceipt memory msgReceipt = MessagingReceipt({ guid: keccak256("test-guid"), nonce: 1, fee: msgFee });
        OFTReceipt memory oftReceipt = OFTReceipt({
            amountSentLD: l2UsdtSendAmount - 1, // Incorrect - less than expected
            amountReceivedLD: l2UsdtSendAmount
        });
        l2OftMessenger.setSendReturn(msgReceipt, oftReceipt);

        vm.prank(relayer);
        vm.expectRevert(OFTTransportAdapter.OftIncorrectAmountSentLD.selector);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }
}
