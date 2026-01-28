// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { Linea_SpokePool } from "../../../../contracts/Linea_SpokePool.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";
import { IMessageService, ITokenBridge } from "../../../../contracts/external/interfaces/LineaInterfaces.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock Linea Message Service
contract MockLineaMessageService {
    address private _sender;
    uint256 private _minimumFeeInWei;

    event SendMessageCalled(address to, uint256 fee, bytes data, uint256 value);

    function setSender(address sender_) external {
        _sender = sender_;
    }

    function sender() external view returns (address) {
        return _sender;
    }

    function setMinimumFeeInWei(uint256 fee) external {
        _minimumFeeInWei = fee;
    }

    function minimumFeeInWei() external view returns (uint256) {
        return _minimumFeeInWei;
    }

    function sendMessage(address _to, uint256 _fee, bytes calldata _calldata) external payable {
        emit SendMessageCalled(_to, _fee, _calldata, msg.value);
    }
}

// Mock Linea Token Bridge
contract MockLineaTokenBridge {
    event BridgeTokenCalled(address token, uint256 amount, address recipient, uint256 value);

    function bridgeToken(address _token, uint256 _amount, address _recipient) external payable {
        emit BridgeTokenCalled(_token, _amount, _recipient, msg.value);
    }
}

contract LineaSpokePoolTest is Test {
    Linea_SpokePool public spokePool;
    MockLineaMessageService public l2MessageService;
    MockLineaTokenBridge public l2TokenBridge;
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
        l2MessageService = new MockLineaMessageService();
        l2TokenBridge = new MockLineaTokenBridge();

        // Fund message service with ETH for impersonation
        vm.deal(address(l2MessageService), 1 ether);

        // Deploy implementation
        Linea_SpokePool implementation = new Linea_SpokePool(
            address(weth),
            60 * 60,
            9 * 60 * 60,
            IERC20(address(0)), // l2Usdc
            ITokenMessenger(address(0)) // cctpTokenMessenger
        );

        // Deploy proxy
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(
                    Linea_SpokePool.initialize,
                    (
                        0,
                        IMessageService(address(l2MessageService)),
                        ITokenBridge(address(l2TokenBridge)),
                        owner,
                        hubPool
                    )
                )
            )
        );
        spokePool = Linea_SpokePool(payable(proxy));

        // Seed spoke pool with tokens
        dai.mint(address(spokePool), amountHeldByPool);

        // Give spoke pool WETH by actually depositing ETH
        vm.deal(address(spokePool), amountHeldByPool);
        vm.prank(address(spokePool));
        weth.deposit{ value: amountHeldByPool }();

        // Fund relayer with ETH for message fees
        vm.deal(relayer, 1 ether);
    }

    // Helper to make calls as the cross-domain admin via the message service
    function _callAsAdmin(bytes memory data) internal {
        l2MessageService.setSender(owner);
        vm.prank(address(l2MessageService));
        (bool success, ) = address(spokePool).call(data);
        require(success, "Admin call failed");
    }

    function testOnlyCrossDomainOwnerUpgradeLogicContract() public {
        // Deploy new implementation
        Linea_SpokePool newImplementation = new Linea_SpokePool(
            address(weth),
            60 * 60,
            9 * 60 * 60,
            IERC20(address(0)),
            ITokenMessenger(address(0))
        );

        // Fails if not called from message service
        vm.prank(rando);
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.upgradeTo(address(newImplementation));

        // Fails if called from message service but sender is not owner
        l2MessageService.setSender(rando);
        vm.prank(address(l2MessageService));
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.upgradeTo(address(newImplementation));

        // Works when called from message service with correct sender
        _callAsAdmin(abi.encodeCall(spokePool.upgradeTo, (address(newImplementation))));
    }

    function testOnlyCrossDomainOwnerCanSetL2MessageService() public {
        vm.prank(rando);
        vm.expectRevert();
        spokePool.setL2MessageService(IMessageService(rando));

        _callAsAdmin(abi.encodeCall(spokePool.setL2MessageService, (IMessageService(rando))));
        assertEq(address(spokePool.l2MessageService()), rando);
    }

    function testOnlyCrossDomainOwnerCanSetL2TokenBridge() public {
        vm.prank(rando);
        vm.expectRevert();
        spokePool.setL2TokenBridge(ITokenBridge(rando));

        _callAsAdmin(abi.encodeCall(spokePool.setL2TokenBridge, (ITokenBridge(rando))));
        assertEq(address(spokePool.l2TokenBridge()), rando);
    }

    function testOnlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        vm.prank(rando);
        vm.expectRevert();
        spokePool.setCrossDomainAdmin(rando);

        _callAsAdmin(abi.encodeCall(spokePool.setCrossDomainAdmin, (rando)));
        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function testOnlyCrossDomainOwnerCanRelayRootBundle() public {
        vm.prank(rando);
        vm.expectRevert("ONLY_COUNTERPART_GATEWAY");
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        _callAsAdmin(abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot)));

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function testMessageFeeMismatchReverts() public {
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

        // Set a minimum fee but don't send it
        l2MessageService.setMinimumFeeInWei(0.01 ether);
        l2MessageService.setSender(address(0)); // Reset sender

        vm.prank(relayer);
        vm.expectRevert("MESSAGE_FEE_MISMATCH");
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    function testBridgeERC20CorrectlyCallsTokenBridge() public {
        uint256 chainId = spokePool.chainId();
        uint256 fee = 0.01 ether;

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

        l2MessageService.setMinimumFeeInWei(fee);
        l2MessageService.setSender(address(0));

        // Expect the BridgeTokenCalled event with the fee as msg.value
        vm.expectEmit(address(l2TokenBridge));
        emit MockLineaTokenBridge.BridgeTokenCalled(address(dai), amountToReturn, hubPool, fee);

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf{ value: fee }(0, leaf, proof);
    }

    function testBridgeWETHCorrectlyCallsMessageService() public {
        uint256 chainId = spokePool.chainId();
        uint256 fee = 0.01 ether;

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

        l2MessageService.setMinimumFeeInWei(fee);
        l2MessageService.setSender(address(0));

        uint256 wethBalanceBefore = weth.balanceOf(address(spokePool));

        // Expect the SendMessageCalled event - WETH is unwrapped and sent as ETH + fee
        vm.expectEmit(address(l2MessageService));
        emit MockLineaMessageService.SendMessageCalled(hubPool, fee, "", amountToReturn + fee);

        vm.prank(relayer);
        spokePool.executeRelayerRefundLeaf{ value: fee }(0, leaf, proof);

        // WETH balance should decrease by amountToReturn
        // (preExecuteLeafHook wraps msg.value, then we withdraw amountToReturn + fee, net change = -amountToReturn)
        assertEq(weth.balanceOf(address(spokePool)), wethBalanceBefore - amountToReturn);
    }
}
