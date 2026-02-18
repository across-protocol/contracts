// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";

/**
 * @title CounterfactualDepositBase
 * @notice Shared logic for all counterfactual deposit executors (CCTP, OFT, SpokePool)
 */
abstract contract CounterfactualDepositBase is ICounterfactualDeposit {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_SCALAR = 10_000;
    uint256 internal constant EXCHANGE_RATE_SCALAR = 1e18;

    /// @notice Sentinel address representing native ETH in withdraw calls.
    address public constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Reads the stored params hash from the clone's appended immutable args and compares.
    /// @param paramsHash keccak256 hash of the caller-supplied route parameters.
    function _verifyParamsHash(bytes32 paramsHash) internal view {
        bytes32 storedHash = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32));
        if (paramsHash != storedHash) revert InvalidParamsHash();
    }

    /**
     * @notice Allows the admin to withdraw any token from this clone (e.g. recovery of stuck funds).
     * @param adminWithdrawAddress Authorized admin address.
     * @param token ERC20 token to withdraw, or NATIVE_ASSET for native ETH.
     * @param to Recipient of the withdrawn tokens.
     * @param amount Amount to withdraw.
     */
    function _adminWithdraw(address adminWithdrawAddress, address token, address to, uint256 amount) internal {
        if (msg.sender != adminWithdrawAddress) revert Unauthorized();
        _transferOut(token, to, amount);
        emit AdminWithdraw(token, to, amount);
    }

    /**
     * @notice Allows the user to withdraw tokens before execution (escape hatch).
     * @param userWithdrawAddress Authorized user address.
     * @param token ERC20 token to withdraw, or NATIVE_ASSET for native ETH.
     * @param to Recipient of the withdrawn tokens.
     * @param amount Amount to withdraw.
     */
    function _userWithdraw(address userWithdrawAddress, address token, address to, uint256 amount) internal {
        if (msg.sender != userWithdrawAddress) revert Unauthorized();
        _transferOut(token, to, amount);
        emit UserWithdraw(token, to, amount);
    }

    /// @dev Transfers native ETH (token == NATIVE_ASSET) or ERC20 tokens.
    function _transferOut(address token, address to, uint256 amount) internal {
        if (token == NATIVE_ASSET) {
            (bool success, ) = to.call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
