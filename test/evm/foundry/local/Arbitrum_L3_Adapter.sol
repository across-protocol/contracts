// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "forge-std/mocks/MockERC20.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { Arbitrum_L3_Adapter } from "../../../../contracts/chain-adapters/Arbitrum_L3_Adapter.sol";
import { Optimism_Adapter } from "../../../../contracts/chain-adapters/Optimism_Adapter.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";

// We normally delegatecall these from the hub pool, which has receive(). In this test, we call the adapter
// directly, so in order to withdraw Weth, we need to have receive().
contract Mock_L3_Adapter is Arbitrum_L3_Adapter {
    constructor(address _adapter, address _l2Forwarder) Arbitrum_L3_Adapter(_adapter, _l2Forwarder) {}

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

contract MinimalWeth is Token_ERC20 {
    constructor(string memory name, string memory symbol) Token_ERC20(name, symbol) {}

    function withdraw(uint256 amount) public {
        _burn(msg.sender, amount);
        (bool success, ) = payable(msg.sender).call{ value: amount }("");
        require(success);
    }
}

contract CrossDomainMessenger {
    event MessageSent(address indexed target);

    function sendMessage(
        address target,
        bytes calldata,
        uint32
    ) external {
        emit MessageSent(target);
    }
}

contract StandardBridge {
    event ETHDepositInitiated(address indexed to, uint256 amount);

    function depositERC20To(
        address l1Token,
        address l2Token,
        address to,
        uint256 amount,
        uint32,
        bytes calldata
    ) external {
        Token_ERC20(l1Token).burn(msg.sender, amount);
        Token_ERC20(l2Token).mint(to, amount);
    }

    function depositETHTo(
        address to,
        uint32,
        bytes calldata
    ) external payable {
        emit ETHDepositInitiated(to, msg.value);
    }
}

contract ArbitrumL3AdapterTest is Test {
    Arbitrum_L3_Adapter l3Adapter;
    Optimism_Adapter optimismAdapter;

    Token_ERC20 l1Token;
    Token_ERC20 l2Token;
    Token_ERC20 l1Weth;
    Token_ERC20 l2Weth;
    CrossDomainMessenger crossDomainMessenger;
    StandardBridge standardBridge;

    address l2Forwarder;

    function setUp() public {
        l2Forwarder = vm.addr(1);

        l1Token = new Token_ERC20("l1Token", "l1Token");
        l2Token = new Token_ERC20("l2Token", "l2Token");
        l1Weth = new MinimalWeth("l1Weth", "l1Weth");
        l2Weth = new MinimalWeth("l2Weth", "l2Weth");

        crossDomainMessenger = new CrossDomainMessenger();
        standardBridge = new StandardBridge();

        optimismAdapter = new Optimism_Adapter(
            WETH9Interface(address(l1Weth)),
            address(crossDomainMessenger),
            IL1StandardBridge(address(standardBridge)),
            IERC20(address(0)),
            ITokenMessenger(address(0))
        );
        l3Adapter = new Mock_L3_Adapter(address(optimismAdapter), l2Forwarder);
    }

    // Messages should be indiscriminately sent to the l2Forwarder.
    function testRelayMessage(address target, bytes memory message) public {
        vm.expectEmit(address(crossDomainMessenger));
        emit CrossDomainMessenger.MessageSent(l2Forwarder);
        l3Adapter.relayMessage(target, message);
    }

    // Sending Weth should call depositETHTo().
    function testRelayWeth(uint256 amountToSend, address random) public {
        vm.deal(address(l1Weth), amountToSend);
        l1Weth.mint(address(l3Adapter), amountToSend);
        assertEq(amountToSend, l1Weth.totalSupply());
        vm.expectEmit(address(standardBridge));
        emit StandardBridge.ETHDepositInitiated(l2Forwarder, amountToSend);
        l3Adapter.relayTokens(address(l1Weth), address(l2Weth), amountToSend, random);
        assertEq(0, l1Weth.totalSupply());
    }

    // Sending any random token should call depositERC20To().
    function testRelayToken(uint256 amountToSend, address random) public {
        l1Token.mint(address(l3Adapter), amountToSend);
        assertEq(amountToSend, l1Token.totalSupply());
        l3Adapter.relayTokens(address(l1Token), address(l2Token), amountToSend, random);
        assertEq(amountToSend, l2Token.balanceOf(l2Forwarder));
        assertEq(amountToSend, l2Token.totalSupply());
        assertEq(0, l1Token.totalSupply());
    }
}
