// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "forge-std/mocks/MockERC20.sol";

import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { FinderInterface } from "@uma/core/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";

import { Router_Adapter } from "../../../../contracts/chain-adapters/Router_Adapter.sol";
import { Optimism_Adapter } from "../../../../contracts/chain-adapters/Optimism_Adapter.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { MockBedrockL1StandardBridge, MockBedrockCrossDomainMessenger } from "../../../../contracts/test/MockBedrockStandardBridge.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { HubPool } from "../../../../contracts/HubPool.sol";
import { LpTokenFactoryInterface } from "../../../../contracts/interfaces/LpTokenFactoryInterface.sol";

// We normally delegatecall these from the hub pool, which has receive(). In this test, we call the adapter
// directly, so in order to withdraw Weth, we need to have receive().
contract Mock_Router_Adapter is Router_Adapter {
    constructor(
        address _l1Adapter,
        address _l2Target,
        uint256 _l2ChainId,
        uint256 _l3ChainId,
        HubPoolInterface _hubPool
    ) Router_Adapter(_l1Adapter, _l2Target, _l2ChainId, _l3ChainId, _hubPool) {}

    receive() external payable {}
}

contract Token_ERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public virtual {
        _burn(from, value);
    }
}

contract RouterAdapterTest is Test {
    Router_Adapter routerAdapter;
    Optimism_Adapter optimismAdapter;

    Token_ERC20 l1Token;
    Token_ERC20 l2Token;
    WETH9 l1Weth;
    WETH9 l2Weth;
    MockBedrockCrossDomainMessenger crossDomainMessenger;
    MockBedrockL1StandardBridge standardBridge;
    HubPool hubPool;

    address l2Target;
    address owner;

    uint256 constant L2_CHAIN_ID = 10;
    uint256 constant L3_CHAIN_ID = 100;

    function setUp() public {
        l2Target = makeAddr("l2Target");
        owner = makeAddr("owner");

        // Temporary values to initialize the hub pool. We do not set a new LP token, nor do we dispute, so these
        // do not need to be contracts.
        address finder = makeAddr("finder");
        address lpTokenFactory = makeAddr("lpTokenFactory");
        address timer = makeAddr("timer");

        l1Token = new Token_ERC20("l1Token", "l1Token");
        l2Token = new Token_ERC20("l2Token", "l2Token");
        l1Weth = new WETH9();
        l2Weth = new WETH9();

        vm.startPrank(owner);
        hubPool = new HubPool(
            LpTokenFactoryInterface(lpTokenFactory),
            FinderInterface(finder),
            WETH9Interface(address(l1Weth)),
            timer
        );
        // Whitelist l1Token and l1Weth for relaying on L2. Note that the hub pool does checks to ensure that the L3 token is whitelisted when it performs
        // a token bridge.
        hubPool.setPoolRebalanceRoute(L2_CHAIN_ID, address(l1Token), address(l2Token));
        hubPool.setPoolRebalanceRoute(L2_CHAIN_ID, address(l1Weth), address(l2Weth));
        vm.stopPrank();

        crossDomainMessenger = new MockBedrockCrossDomainMessenger();
        standardBridge = new MockBedrockL1StandardBridge();

        optimismAdapter = new Optimism_Adapter(
            WETH9Interface(address(l1Weth)),
            address(crossDomainMessenger),
            IL1StandardBridge(address(standardBridge)),
            IERC20(address(0)),
            ITokenMessenger(address(0))
        );
        routerAdapter = new Mock_Router_Adapter(address(optimismAdapter), l2Target, L2_CHAIN_ID, L3_CHAIN_ID, hubPool);
    }

    // Messages should be indiscriminately sent to the l2Forwarder.
    function testRelayMessage(address target, bytes memory message) public {
        vm.assume(target != l2Target);
        vm.expectEmit(address(crossDomainMessenger));
        emit MockBedrockCrossDomainMessenger.MessageSent(l2Target);
        routerAdapter.relayMessage(target, message);
    }

    // Sending Weth should call depositETHTo().
    function testRelayWeth(uint256 amountToSend, address random) public {
        // Prevent fuzz testing with amountToSend * 2 > 2^256
        amountToSend = uint256(bound(amountToSend, 1, 2**254));
        vm.deal(address(l1Weth), amountToSend);
        vm.deal(address(routerAdapter), amountToSend);

        vm.startPrank(address(routerAdapter));
        l1Weth.deposit{ value: amountToSend }();
        vm.stopPrank();

        assertEq(amountToSend * 2, l1Weth.totalSupply());
        vm.expectEmit(address(standardBridge));
        emit MockBedrockL1StandardBridge.ETHDepositInitiated(l2Target, amountToSend);
        routerAdapter.relayTokens(address(l1Weth), address(l2Weth), amountToSend, random);
        assertEq(0, l1Weth.balanceOf(address(routerAdapter)));
    }

    // Sending any random token should call depositERC20To().
    function testRelayToken(uint256 amountToSend, address random) public {
        l1Token.mint(address(routerAdapter), amountToSend);
        assertEq(amountToSend, l1Token.totalSupply());

        vm.expectEmit(address(standardBridge));
        emit MockBedrockL1StandardBridge.ERC20DepositInitiated(
            l2Target,
            address(l1Token),
            address(l2Token),
            amountToSend
        );
        routerAdapter.relayTokens(address(l1Token), address(l2Token), amountToSend, random);
        assertEq(0, l1Token.balanceOf(address(routerAdapter)));
    }
}
