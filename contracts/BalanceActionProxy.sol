// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BalanceActionProxy
 * @notice Stateless contract designed to be called via delegatecall. Transfers or approves the caller's full balance
 * of a specified ERC20 token. Because execution happens in the caller's context, `address(this)` resolves to the
 * calling contract and `balanceOf(address(this))` returns the caller's balance.
 * @dev Must only be used via delegatecall — a direct call would act on this contract's own (zero) balances.
 */
contract BalanceActionProxy {
    using SafeERC20 for IERC20;

    /**
     * @notice Transfers the caller's full balance of `token` to `to`.
     * @param token ERC20 token to transfer.
     * @param to Recipient address.
     */
    function transferBalance(IERC20 token, address to) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) token.safeTransfer(to, balance);
    }

    /**
     * @notice Approves `spender` for the caller's full balance of `token`.
     * @param token ERC20 token to approve.
     * @param spender Address to approve.
     */
    function approveBalance(IERC20 token, address spender) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) token.forceApprove(spender, balance);
    }
}
