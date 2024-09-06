// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Users can donate tokens to this contract that only the owner can withdraw.
 * @dev This contract is designed to be used as a convience for the owner to store funds to pay for
 * future transactions, such as donating custom gas tokens to pay for future retryable ticket messages
 * to be sent via the Arbitrum_Adapter.
 */
contract DonationBox is Ownable {
    using SafeERC20 for IERC20;

    /**
     * @notice Withdraw tokens from the contract.
     * @param token Token to withdraw.
     * @param amount Amount of tokens to withdraw.
     */
    function withdraw(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(msg.sender, amount);
    }
}
