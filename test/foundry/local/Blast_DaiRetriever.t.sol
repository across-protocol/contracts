// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "forge-std/mocks/MockERC20.sol";
import { ERC20 } from "@openzeppelin/contracts5/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts5/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts5/token/ERC20/utils/SafeERC20.sol";

import { Blast_DaiRetriever } from "../../../contracts/Blast_DaiRetriever.sol";
import { MockBlastUsdYieldManager } from "../../../contracts/test/MockBlastUsdYieldManager.sol";

contract Token_ERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }
}

contract BlastDaiRetrieverTest is Test {
    Blast_DaiRetriever daiRetriever;
    MockBlastUsdYieldManager usdYieldManager;
    Token_ERC20 dai;

    // EOA caller of retrieve().
    address rando;

    // HubPool should receive funds.
    address hubPool;

    uint256 requestId = 2;
    uint256 hintId = 3;

    function setUp() public {
        dai = new Token_ERC20("DAI", "DAI");
        rando = vm.addr(1);
        hubPool = vm.addr(2);

        usdYieldManager = new MockBlastUsdYieldManager();
        daiRetriever = new Blast_DaiRetriever(hubPool, usdYieldManager, IERC20(address(dai)));
    }

    function testRetrieveSuccess() public {
        assertEq(dai.balanceOf(hubPool), 0);
        assertEq(dai.balanceOf(rando), 0);
        assertEq(dai.balanceOf(address(daiRetriever)), 0);
        uint256 daiTransferAmount = 10**22;
        dai.mint(address(daiRetriever), daiTransferAmount);
        vm.startPrank(rando);

        // Make sure claimWithdrawal is called with correct params and returns true.
        vm.expectCall(address(usdYieldManager), abi.encodeCall(usdYieldManager.claimWithdrawal, (requestId, hintId)));
        daiRetriever.retrieve(requestId, hintId);

        // Make sure DAI is transferred to hubPool.
        assertEq(dai.balanceOf(hubPool), daiTransferAmount);
        assertEq(dai.balanceOf(rando), 0);
        assertEq(dai.balanceOf(address(daiRetriever)), 0);
        vm.stopPrank();
    }

    function testRetrieveFailure() public {
        // Check that daiRetriever reverts if claimWithdrawal returns false.
        usdYieldManager.setShouldFail(true);
        vm.startPrank(rando);
        vm.expectRevert();
        daiRetriever.retrieve(requestId, hintId);
        vm.stopPrank();
    }
}
