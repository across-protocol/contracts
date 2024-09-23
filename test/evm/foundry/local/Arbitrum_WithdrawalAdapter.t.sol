// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "forge-std/mocks/MockERC20.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Arbitrum_WithdrawalAdapter } from "../../../../contracts/chain-adapters/l2/Arbitrum_WithdrawalAdapter.sol";
import { L2_TokenRetriever } from "../../../../contracts/L2_TokenRetriever.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

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
    mapping(address => address) l2TokenAddress;

    function outboundTransfer(
        address tokenToBridge,
        address recipient,
        uint256 amountToReturn,
        bytes memory
    ) external returns (bytes memory) {
        address l2Token = l2TokenAddress[tokenToBridge];
        Token_ERC20(l2Token).burn(msg.sender, amountToReturn);
        Token_ERC20(tokenToBridge).mint(recipient, amountToReturn);
        return "";
    }

    function calculateL2TokenAddress(address l1Token) external view returns (address) {
        return l2TokenAddress[l1Token];
    }

    function setTokenPair(address l1Token, address l2Token) external {
        l2TokenAddress[l1Token] = l2Token;
    }
}

contract Arbitrum_WithdrawalAdapterTest is Test {
    Arbitrum_WithdrawalAdapter arbitrumWithdrawalAdapter;
    L2_TokenRetriever tokenRetriever;
    ArbitrumGatewayRouter gatewayRouter;
    Token_ERC20 l1Token;
    Token_ERC20 l2Token;
    Token_ERC20 l2Usdc;

    // HubPool should receive funds.
    address hubPool;

    // Token messenger is set so CCTP is activated.
    ITokenMessenger tokenMessenger;

    error RetrieveFailed();

    function setUp() public {
        l1Token = new Token_ERC20("TOKEN", "TOKEN");
        l2Token = new Token_ERC20("TOKEN", "TOKEN");
        l2Usdc = new Token_ERC20("USDC", "USDC");
        gatewayRouter = new ArbitrumGatewayRouter();

        // Instantiate all other addresses used in the system.
        tokenMessenger = ITokenMessenger(vm.addr(1));
        hubPool = vm.addr(2);

        gatewayRouter.setTokenPair(address(l1Token), address(l2Token));
        arbitrumWithdrawalAdapter = new Arbitrum_WithdrawalAdapter(l2Usdc, tokenMessenger, address(gatewayRouter));
        tokenRetriever = new L2_TokenRetriever(address(arbitrumWithdrawalAdapter), hubPool);
    }

    function testWithdrawToken(uint256 amountToReturn) public {
        l2Token.mint(address(tokenRetriever), amountToReturn);
        assertEq(amountToReturn, l2Token.totalSupply());
        L2_TokenRetriever.TokenPair[] memory tokenPairs = new L2_TokenRetriever.TokenPair[](1);
        tokenPairs[0] = L2_TokenRetriever.TokenPair({ l1Token: address(l1Token), l2Token: address(l2Token) });
        tokenRetriever.retrieve(tokenPairs);
        assertEq(0, l2Token.totalSupply());
        assertEq(amountToReturn, l1Token.totalSupply());
        assertEq(l1Token.balanceOf(hubPool), amountToReturn);
    }

    function testWithdrawTokenFailure(uint256 amountToReturn, address invalidToken) public {
        l2Token.mint(address(tokenRetriever), amountToReturn);
        assertEq(amountToReturn, l2Token.totalSupply());
        L2_TokenRetriever.TokenPair[] memory tokenPairs = new L2_TokenRetriever.TokenPair[](1);
        tokenPairs[0] = L2_TokenRetriever.TokenPair({ l1Token: invalidToken, l2Token: address(l2Token) });
        vm.expectRevert(L2_TokenRetriever.RetrieveFailed.selector);
        tokenRetriever.retrieve(tokenPairs);
    }
}
