// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessControl } from "@openzeppelin/contracts-v4/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Users can donate tokens to this contract that only authorized withdrawers can withdraw.
 * @dev This contract is designed to be used as a convenience for storing funds to pay for
 * future transactions, such as donating custom gas tokens to pay for future retryable ticket messages
 * to be sent via the Arbitrum_Adapter.
 * @dev Multiple addresses can be granted the WITHDRAWER_ROLE to withdraw funds.
 * @custom:security-contact bugs@across.to
 */
contract DonationBox is AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Role for addresses authorized to withdraw funds
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(WITHDRAWER_ROLE, msg.sender);
    }

    /**
     * @notice Withdraw tokens from the contract.
     * @dev Only callable by addresses with WITHDRAWER_ROLE.
     * @param token Token to withdraw.
     * @param amount Amount of tokens to withdraw.
     */
    function withdraw(IERC20 token, uint256 amount) external onlyRole(WITHDRAWER_ROLE) {
        token.safeTransfer(msg.sender, amount);
    }
}
