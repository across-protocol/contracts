// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "forge-std/mocks/MockERC20.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Arbitrum_SpokePool, ITokenMessenger } from "../../../../contracts/Arbitrum_SpokePool.sol";
import { Arbitrum_WithdrawalAdapter, IArbitrum_SpokePool } from "../../../../contracts/chain-adapters/l2/Arbitrum_WithdrawalAdapter.sol";
import { L2_TokenRetriever } from "../../../../contracts/L2_TokenRetriever.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "forge-std/console.sol";

contract Token_ERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public virtual {
        _burn(from, value);
    }
}

contract ArbitrumGatewayRouter {
    function outboundTransfer(
        address tokenToBridge,
        address recipient,
        uint256 amountToReturn,
        bytes memory
    ) external returns (bytes memory) {
        Token_ERC20(tokenToBridge).burn(msg.sender, amountToReturn);
        Token_ERC20(tokenToBridge).mint(recipient, amountToReturn);
        return "";
    }
}

contract Arbitrum_WithdrawalAdapterTest is Test {
    Arbitrum_WithdrawalAdapter arbitrumWithdrawalAdapter;
    L2_TokenRetriever tokenRetriever;
    Arbitrum_SpokePool arbitrumSpokePool;
    Token_ERC20 whitelistedToken;
    Token_ERC20 usdc;
    ArbitrumGatewayRouter gatewayRouter;

    // HubPool should receive funds.
    address hubPool;
    address owner;
    address aliasedOwner;
    address wrappedNativeToken;

    // Token messenger is set so CCTP is activated.
    ITokenMessenger tokenMessenger;

    error RetrieveFailed(address l2Token);
    error RetrieveManyFailed(address[] l2Tokens);

    function setUp() public {
        // Initialize mintable/burnable tokens.
        whitelistedToken = new Token_ERC20("TOKEN", "TOKEN");
        usdc = new Token_ERC20("USDC", "USDC");
        // Initialize mock bridge.
        gatewayRouter = new ArbitrumGatewayRouter();

        // Instantiate all other addresses used in the system.
        tokenMessenger = ITokenMessenger(vm.addr(1));
        owner = vm.addr(2);
        wrappedNativeToken = vm.addr(3);
        hubPool = vm.addr(4);
        aliasedOwner = _applyL1ToL2Alias(owner);

        // Create the spoke pool.
        vm.startPrank(owner);
        Arbitrum_SpokePool implementation = new Arbitrum_SpokePool(wrappedNativeToken, 0, 0, usdc, tokenMessenger);
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(Arbitrum_SpokePool.initialize, (0, address(gatewayRouter), owner, owner))
            )
        );
        vm.stopPrank();
        arbitrumSpokePool = Arbitrum_SpokePool(payable(proxy));
        arbitrumWithdrawalAdapter = new Arbitrum_WithdrawalAdapter(
            usdc,
            tokenMessenger,
            IArbitrum_SpokePool(proxy),
            address(gatewayRouter)
        );

        // Create the token retriever contract.
        tokenRetriever = new L2_TokenRetriever(address(arbitrumWithdrawalAdapter), hubPool);
    }

    function testWithdrawWhitelistedTokenNonCCTP(uint256 amountToReturn) public {
        // There should be no balance in any contract/EOA.
        assertEq(whitelistedToken.balanceOf(hubPool), 0);
        assertEq(whitelistedToken.balanceOf(owner), 0);
        assertEq(whitelistedToken.balanceOf(address(tokenRetriever)), 0);

        // Whitelist tokens in the spoke pool and simulate a L3 -> L2 withdrawal into the token retriever.
        vm.startPrank(aliasedOwner);
        arbitrumSpokePool.whitelistToken(address(whitelistedToken), address(whitelistedToken));
        vm.stopPrank();
        whitelistedToken.mint(address(tokenRetriever), amountToReturn);

        // Attempt to withdraw the token.
        tokenRetriever.retrieve(address(whitelistedToken));

        // Ensure that the balances are updated (i.e. the token bridge contract was called).
        assertEq(whitelistedToken.balanceOf(hubPool), amountToReturn);
        assertEq(whitelistedToken.balanceOf(owner), 0);
        assertEq(whitelistedToken.balanceOf(address(tokenRetriever)), 0);
    }

    function testWithdrawOtherTokenNonCCTP(uint256 amountToReturn) public {
        // There should be no balance in any contract/EOA.
        assertEq(whitelistedToken.balanceOf(hubPool), 0);
        assertEq(whitelistedToken.balanceOf(owner), 0);
        assertEq(whitelistedToken.balanceOf(address(tokenRetriever)), 0);

        // Simulate a L3 -> L2 withdrawal of an non-whitelisted token to the tokenRetriever contract.
        whitelistedToken.mint(address(tokenRetriever), amountToReturn);

        // Attempt to withdraw the token.
        vm.expectRevert(abi.encodeWithSelector(RetrieveFailed.selector, address(whitelistedToken)));
        tokenRetriever.retrieve(address(whitelistedToken));
    }

    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        // Allows overflows as explained above.
        unchecked {
            l2Address = address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
        }
    }
}
