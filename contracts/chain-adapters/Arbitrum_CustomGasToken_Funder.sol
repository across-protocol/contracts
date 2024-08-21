// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Arbitrum_CustomGasToken_Funder is Ownable {
    using SafeERC20 for IERC20;

    /**
     * @notice Deposit tokens into the contract.
     * @param token Token to deposit.
     * @param amount Amount of tokens to deposit.
     */
    function deposit(IERC20 token, uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw tokens from the contract.
     * @param token Token to withdraw.
     * @param amount Amount of tokens to withdraw.
     */
    function withdraw(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(msg.sender, amount);
    }
}
