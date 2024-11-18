// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "forge-std/mocks/MockERC20.sol";

import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Optimism_Adapter } from "../../../../contracts/chain-adapters/Optimism_Adapter.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { MockBedrockL1StandardBridge, MockBedrockCrossDomainMessenger } from "../../../../contracts/test/MockBedrockStandardBridge.sol";
import { Arbitrum_Forwarder } from "../../../../contracts/chain-adapters/Arbitrum_Forwarder.sol";
import { ForwarderBase } from "../../../../contracts/chain-adapters/ForwarderBase.sol";
import { CrossDomainAddressUtils } from "../../../../contracts/libraries/CrossDomainAddressUtils.sol";
import { ForwarderInterface } from "../../../../contracts/chain-adapters/interfaces/ForwarderInterface.sol";

contract Token_ERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public virtual {
        _burn(from, value);
    }
}

contract ForwarderTest is Test {
    Arbitrum_Forwarder arbitrumForwarder;
    Optimism_Adapter optimismAdapter;

    Token_ERC20 l2Token;
    Token_ERC20 l3Token;
    WETH9 l2Weth;
    MockBedrockCrossDomainMessenger crossDomainMessenger;
    MockBedrockL1StandardBridge standardBridge;

    address owner;
    address aliasedOwner;

    uint256 constant L3_CHAIN_ID = 100;

    function setUp() public {
        owner = makeAddr("owner");
        aliasedOwner = CrossDomainAddressUtils.applyL1ToL2Alias(owner);

        l2Token = new Token_ERC20("l1Token", "l1Token");
        l3Token = new Token_ERC20("l2Token", "l2Token");
        l2Weth = new WETH9();

        crossDomainMessenger = new MockBedrockCrossDomainMessenger();
        standardBridge = new MockBedrockL1StandardBridge();

        optimismAdapter = new Optimism_Adapter(
            WETH9Interface(address(l2Weth)),
            address(crossDomainMessenger),
            IL1StandardBridge(address(standardBridge)),
            IERC20(address(0)),
            ITokenMessenger(address(0))
        );

        arbitrumForwarder = new Arbitrum_Forwarder(WETH9Interface(address(l2Weth)));
        address proxy = address(
            new ERC1967Proxy(address(arbitrumForwarder), abi.encodeCall(Arbitrum_Forwarder.initialize, (owner)))
        );
        arbitrumForwarder = Arbitrum_Forwarder(payable(proxy));

        vm.startPrank(aliasedOwner);
        arbitrumForwarder.updateAdapter(L3_CHAIN_ID, address(optimismAdapter));
        vm.stopPrank();
    }

    // Messages should be routed through the Optimism Adapter's `relayMessage` function.
    function testForwardMessage(address target, bytes memory message) public {
        vm.expectRevert();
        arbitrumForwarder.relayMessage(target, L3_CHAIN_ID, message);

        vm.startPrank(aliasedOwner);
        vm.expectEmit(address(crossDomainMessenger));
        emit MockBedrockCrossDomainMessenger.MessageSent(target);
        arbitrumForwarder.relayMessage(target, L3_CHAIN_ID, message);
        vm.stopPrank();
    }

    // Token relays should first be saved to state (when called by the cross domain admin).
    // In a follow-up `sendTokens` call, tokens should then be routed through the Optimism
    // Adapter's `relayTokens` function.
    function testForwardTokens(uint256 amountToSend, address random) public {
        l2Token.mint(address(arbitrumForwarder), amountToSend);
        vm.expectRevert();
        arbitrumForwarder.relayTokens(address(l2Token), address(l3Token), amountToSend, L3_CHAIN_ID, random);

        // Save token info to state.
        vm.startPrank(aliasedOwner);
        vm.expectEmit(address(arbitrumForwarder));
        emit ForwarderInterface.ReceivedTokenRelay(
            0,
            ForwarderInterface.TokenRelay(address(l2Token), address(l3Token), random, amountToSend, L3_CHAIN_ID, false)
        );
        arbitrumForwarder.relayTokens(address(l2Token), address(l3Token), amountToSend, L3_CHAIN_ID, random);
        vm.stopPrank();

        // Execute a saved token relay.
        vm.startPrank(random);
        vm.expectEmit(address(standardBridge));
        emit MockBedrockL1StandardBridge.ERC20DepositInitiated(
            random,
            address(l2Token),
            address(l3Token),
            amountToSend
        );
        arbitrumForwarder.executeRelayTokens(0);

        // Verify a relay cannot be executed twice.
        vm.expectRevert(ForwarderInterface.TokenRelayExecuted.selector);
        arbitrumForwarder.executeRelayTokens(0);
        vm.stopPrank();
    }

    // Attempting to send a message to an uninitialized adapter should revert
    function testUninitializedAdapter(
        address target,
        uint256 randomChainId,
        bytes memory message
    ) public {
        vm.assume(randomChainId != L3_CHAIN_ID);
        vm.startPrank(aliasedOwner);
        vm.expectRevert(ForwarderBase.UninitializedChainAdapter.selector);
        arbitrumForwarder.relayMessage(target, randomChainId, message);
        vm.stopPrank();
    }

    // Test access control on proxy upgrades.
    function testUpgrade(address random) public {
        vm.assume(random != aliasedOwner);
        address newImplementation = address(new Arbitrum_Forwarder(WETH9Interface(address(l2Weth))));
        vm.startPrank(random);
        vm.expectRevert();
        arbitrumForwarder.upgradeTo(newImplementation);
        vm.stopPrank();

        vm.startPrank(aliasedOwner);
        arbitrumForwarder.upgradeTo(newImplementation);
        vm.stopPrank();
    }
}
