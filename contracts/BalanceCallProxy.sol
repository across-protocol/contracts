// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/**
 * @title BalanceCallProxy
 * @notice DRAFT. Stateless contract designed to be called via delegatecall. Executes a sequence of external calls
 * with runtime balance injection — token or native balances are read and ORed into calldata at specified byte
 * offsets before each call is made. Because execution happens in the caller's context, `address(this)` resolves
 * to the calling contract, so balance reads and state mutations apply to the caller.
 * @dev Must only be used via delegatecall — a direct call would operate on this contract's own (zero) balances.
 * Replacements are applied just before each call executes, so later calls can reference balances that changed
 * from earlier calls (e.g., call 0 swaps tokenA→tokenB, call 1 injects the new tokenB balance).
 * Balance values are ORed into calldata — target positions must be zeroed out by the caller.
 */
contract BalanceCallProxy {
    struct Call {
        address target;
        bytes callData;
        uint256 value;
    }

    struct Replacement {
        address token; // ERC20 address, or address(0) for native balance.
        uint256 callIndex; // Which call in the array this replacement targets.
        uint256 offset; // Byte offset in callData where the balance should be injected.
    }

    error CallFailed(uint256 index);
    error CalldataTooShort(uint256 callIndex, uint256 calldataLength, uint256 offset);

    /**
     * @notice Executes a sequence of calls, injecting token/native balances into calldata at specified positions.
     * @dev Replacements must be sorted by callIndex (ascending). For each call, all matching replacements are
     * applied immediately before execution. For native balance replacements (token = address(0)), the call's
     * value field is overwritten with the full native balance.
     * @param calls Ordered external calls to execute.
     * @param replacements Balance injection descriptors, sorted by callIndex.
     */
    function execute(Call[] memory calls, Replacement[] calldata replacements) external {
        uint256 numCalls = calls.length;
        uint256 numReplacements = replacements.length;
        uint256 r = 0;

        for (uint256 i = 0; i < numCalls; ++i) {
            // Apply all replacements targeting this call index.
            for (; r < numReplacements && replacements[r].callIndex == i; ++r) {
                _injectBalance(calls[i], replacements[r].token, replacements[r].offset, i);
            }

            (bool success, ) = calls[i].target.call{ value: calls[i].value }(calls[i].callData);
            if (!success) revert CallFailed(i);
        }
    }

    /**
     * @dev Reads a token (or native) balance and ORs it into the call's calldata at the given byte offset.
     * For native balance, also overwrites the call's value with the full balance.
     */
    function _injectBalance(Call memory call_, address token, uint256 offset, uint256 callIndex) private view {
        bytes memory callData = call_.callData;
        uint256 bal;

        if (token != address(0)) {
            bal = IERC20(token).balanceOf(address(this));
        } else {
            bal = address(this).balance;
            call_.value = bal;
        }

        // +32 to skip the memory length prefix of `bytes`.
        uint256 memOffset = offset + 32;
        if (memOffset > callData.length) revert CalldataTooShort(callIndex, callData.length, offset);

        assembly ("memory-safe") {
            let ptr := add(callData, memOffset)
            mstore(ptr, or(mload(ptr), bal))
        }
    }
}
