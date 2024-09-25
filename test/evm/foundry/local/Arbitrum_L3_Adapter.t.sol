// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "forge-std/mocks/MockERC20.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { Rerouter_Adapter } from "../../../../contracts/chain-adapters/Rerouter_Adapter.sol";
import { Optimism_Adapter } from "../../../../contracts/chain-adapters/Optimism_Adapter.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { MockBedrockL1StandardBridge, MockBedrockCrossDomainMessenger } from "../../../../contracts/test/MockBedrockStandardBridge.sol";

import "forge-std/console.sol";

// We normally delegatecall these from the hub pool, which has receive(). In this test, we call the adapter
// directly, so in order to withdraw Weth, we need to have receive().
contract Mock_Rerouter_Adapter is Rerouter_Adapter {
    constructor(address _l1Adapter, address _l2Target) Rerouter_Adapter(_l1Adapter, _l2Target) {}

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

contract ArbitrumL3AdapterTest is Test {
    Rerouter_Adapter l3Adapter;
    Optimism_Adapter optimismAdapter;

    Token_ERC20 l1Token;
    Token_ERC20 l2Token;
    WETH9 l1Weth;
    WETH9 l2Weth;
    MockBedrockCrossDomainMessenger crossDomainMessenger;
    MockBedrockL1StandardBridge standardBridge;

    address l2Target;

    function setUp() public {
        l2Target = makeAddr("l2Target");

        l1Token = new Token_ERC20("l1Token", "l1Token");
        l2Token = new Token_ERC20("l2Token", "l2Token");
        l1Weth = new WETH9();
        l2Weth = new WETH9();

        crossDomainMessenger = new MockBedrockCrossDomainMessenger();
        standardBridge = new MockBedrockL1StandardBridge();

        optimismAdapter = new Optimism_Adapter(
            WETH9Interface(address(l1Weth)),
            address(crossDomainMessenger),
            IL1StandardBridge(address(standardBridge)),
            IERC20(address(0)),
            ITokenMessenger(address(0))
        );
        l3Adapter = new Mock_Rerouter_Adapter(address(optimismAdapter), l2Target);
    }

    // Messages should be indiscriminately sent to the l2Forwarder.
    function testRelayMessage(address target, bytes memory message) public {
        vm.assume(target != l2Target);
        vm.expectEmit(address(crossDomainMessenger));
        emit MockBedrockCrossDomainMessenger.MessageSent(l2Target);
        l3Adapter.relayMessage(target, message);
    }

    // Sending Weth should call depositETHTo().
    function testRelayWeth(uint256 amountToSend, address random) public {
        // Prevent fuzz testing with amountToSend * 2 > 2^256
        amountToSend = uint256(bound(amountToSend, 1, 2**254));
        vm.deal(address(l1Weth), amountToSend);
        vm.deal(address(l3Adapter), amountToSend);

        vm.startPrank(address(l3Adapter));
        l1Weth.deposit{ value: amountToSend }();
        vm.stopPrank();

        assertEq(amountToSend * 2, l1Weth.totalSupply());
        vm.expectEmit(address(standardBridge));
        emit MockBedrockL1StandardBridge.ETHDepositInitiated(l2Target, amountToSend);
        l3Adapter.relayTokens(address(l1Weth), address(l2Weth), amountToSend, random);
        assertEq(0, l1Weth.balanceOf(address(l3Adapter)));
    }

    // Sending any random token should call depositERC20To().
    function testRelayToken(uint256 amountToSend, address random) public {
        l1Token.mint(address(l3Adapter), amountToSend);
        assertEq(amountToSend, l1Token.totalSupply());

        vm.expectEmit(address(standardBridge));
        emit MockBedrockL1StandardBridge.ERC20DepositInitiated(
            l2Target,
            address(l1Token),
            address(l2Token),
            amountToSend
        );
        l3Adapter.relayTokens(address(l1Token), address(l2Token), amountToSend, random);
        assertEq(0, l1Token.balanceOf(address(l3Adapter)));
    }
}
