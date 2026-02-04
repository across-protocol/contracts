// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { BondToken, ExtendedHubPoolInterface } from "../../../../contracts/BondToken.sol";

/**
 * @title BondToken_ERC20Test
 * @notice Foundry tests for BondToken ERC20 functions.
 * @dev Most of this functionality falls through to the underlying WETH9 implementation.
 *      Testing here just demonstrates that ABT doesn't break anything.
 */
contract BondToken_ERC20Test is Test {
    // ============ Events ============

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);
    event Transfer(address indexed from, address indexed to, uint256 value);

    // ============ Constants ============

    string constant BOND_TOKEN_NAME = "Across Bond Token";
    string constant BOND_TOKEN_SYMBOL = "ABT";
    uint8 constant BOND_TOKEN_DECIMALS = 18;
    uint256 constant BOND_AMOUNT = 5 ether;

    // ============ State ============

    BondToken public bondToken;
    address public owner;
    address public other;
    address public rando;

    // ============ Setup ============

    function setUp() public {
        owner = address(this);
        other = makeAddr("other");
        rando = makeAddr("rando");

        // Create a mock HubPool address (BondToken only needs its address for construction)
        address mockHubPool = makeAddr("hubPool");
        vm.etch(mockHubPool, hex"00");

        bondToken = new BondToken(ExtendedHubPoolInterface(mockHubPool));

        // Fund test addresses with ETH
        vm.deal(owner, 100 ether);
        vm.deal(other, 100 ether);
        vm.deal(rando, 100 ether);
    }

    // ============ Helper Functions ============

    function _seedBondToken(address user, uint256 amount) internal {
        vm.prank(user);
        bondToken.deposit{ value: amount }();
    }

    // ============ Tests ============

    function test_VerifyNameSymbolAndDecimals() public view {
        assertEq(bondToken.name(), BOND_TOKEN_NAME);
        assertEq(bondToken.symbol(), BOND_TOKEN_SYMBOL);
        assertEq(bondToken.decimals(), BOND_TOKEN_DECIMALS);
    }

    function test_AnyoneCanDepositIntoABT() public {
        // Owner deposits
        vm.expectEmit(true, true, true, true);
        emit Deposit(owner, BOND_AMOUNT);
        bondToken.deposit{ value: BOND_AMOUNT }();
        assertEq(bondToken.balanceOf(owner), BOND_AMOUNT);

        // Other deposits
        vm.expectEmit(true, true, true, true);
        emit Deposit(other, BOND_AMOUNT);
        vm.prank(other);
        bondToken.deposit{ value: BOND_AMOUNT }();
        assertEq(bondToken.balanceOf(other), BOND_AMOUNT);
    }

    function test_ABTHoldersCanWithdraw() public {
        // Test owner withdrawal
        _seedBondToken(owner, BOND_AMOUNT);
        assertEq(bondToken.balanceOf(owner), BOND_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit Withdrawal(owner, BOND_AMOUNT);
        bondToken.withdraw(BOND_AMOUNT);
        assertEq(bondToken.balanceOf(owner), 0);

        // Test other withdrawal
        _seedBondToken(other, BOND_AMOUNT);
        assertEq(bondToken.balanceOf(other), BOND_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit Withdrawal(other, BOND_AMOUNT);
        vm.prank(other);
        bondToken.withdraw(BOND_AMOUNT);
        assertEq(bondToken.balanceOf(other), 0);

        // Test rando withdrawal
        _seedBondToken(rando, BOND_AMOUNT);
        assertEq(bondToken.balanceOf(rando), BOND_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit Withdrawal(rando, BOND_AMOUNT);
        vm.prank(rando);
        bondToken.withdraw(BOND_AMOUNT);
        assertEq(bondToken.balanceOf(rando), 0);
    }

    function test_ABTHoldersCanTransfer() public {
        _seedBondToken(other, BOND_AMOUNT);

        assertEq(bondToken.balanceOf(other), BOND_AMOUNT);
        assertEq(bondToken.balanceOf(rando), 0);

        vm.expectEmit(true, true, true, true);
        emit Transfer(other, rando, BOND_AMOUNT);
        vm.prank(other);
        bondToken.transfer(rando, BOND_AMOUNT);

        assertEq(bondToken.balanceOf(other), 0);
        assertEq(bondToken.balanceOf(rando), BOND_AMOUNT);
    }

    // Allow contract to receive ETH (for withdraw tests)
    receive() external payable {}
}
