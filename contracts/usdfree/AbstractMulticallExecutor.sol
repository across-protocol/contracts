// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { MulticallCall, MulticallInstructions, MulticallReplacement } from "./ExecutorV1Interfaces.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

abstract contract AbstractMulticallExecutor {
    using SafeERC20 for IERC20;
    using Address for address payable;

    event CallsFailed(MulticallCall[] calls, address indexed fallbackRecipient);
    event DrainedTokens(address indexed recipient, address indexed token, uint256 indexed amount);

    error CallReverted(uint256 index, MulticallCall[] calls);
    error NotSelf();
    error InvalidCall(uint256 index, MulticallCall[] calls);
    error ReplacementCallFailed(bytes callData);
    error CalldataTooShort(uint256 callDataLength, uint256 offset);

    modifier onlySelf() {
        _requireSelf();
        _;
    }

    function _executeMulticall(bytes memory data, address tokenForDrain) internal {
        if (data.length == 0) return;
        MulticallInstructions memory instructions = abi.decode(data, (MulticallInstructions));

        if (instructions.fallbackRecipient == address(0)) {
            this.attemptCalls(instructions.calls);
            return;
        }

        (bool success, ) = address(this).call(abi.encodeCall(this.attemptCalls, (instructions.calls)));
        if (!success) emit CallsFailed(instructions.calls, instructions.fallbackRecipient);

        _drainRemainingTokens(tokenForDrain, payable(instructions.fallbackRecipient));
        if (tokenForDrain != address(0)) _drainRemainingTokens(address(0), payable(instructions.fallbackRecipient));
    }

    function attemptCalls(MulticallCall[] memory calls) external onlySelf {
        uint256 length = calls.length;
        for (uint256 i; i < length; ++i) {
            MulticallCall memory c = calls[i];
            if (c.callData.length > 0 && c.target.code.length == 0) revert InvalidCall(i, calls);
            (bool success, ) = c.target.call{ value: c.value }(c.callData);
            if (!success) revert CallReverted(i, calls);
        }
    }

    function drainLeftoverTokens(address token, address payable destination) external onlySelf {
        _drainRemainingTokens(token, destination);
    }

    function makeCallWithBalance(
        address target,
        bytes memory callData,
        uint256 value,
        MulticallReplacement[] calldata replacement
    ) external onlySelf {
        for (uint256 i = 0; i < replacement.length; ++i) {
            uint256 bal = 0;
            if (replacement[i].token != address(0)) {
                bal = IERC20(replacement[i].token).balanceOf(address(this));
            } else {
                bal = address(this).balance;
                value = bal;
            }

            uint256 offset = replacement[i].offset + 32;
            if (offset > callData.length) revert CalldataTooShort(callData.length, offset);

            assembly ("memory-safe") {
                let ptr := add(callData, offset)
                mstore(ptr, bal)
            }
        }

        (bool success, ) = target.call{ value: value }(callData);
        if (!success) revert ReplacementCallFailed(callData);
    }

    function _drainRemainingTokens(address token, address payable destination) internal {
        if (token != address(0)) {
            uint256 tokenAmount = IERC20(token).balanceOf(address(this));
            if (tokenAmount > 0) {
                IERC20(token).safeTransfer(destination, tokenAmount);
                emit DrainedTokens(destination, token, tokenAmount);
            }
            return;
        }

        uint256 nativeAmount = address(this).balance;
        if (nativeAmount > 0) destination.sendValue(nativeAmount);
    }

    function _requireSelf() internal view {
        if (msg.sender != address(this)) revert NotSelf();
    }

    receive() external payable virtual {}
}
