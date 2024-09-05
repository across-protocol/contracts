// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts5/access/Ownable.sol";
import "@openzeppelin/contracts5/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts5/token/ERC20/utils/SafeERC20.sol";

contract Arbitrum_CustomGasToken_Funder is Ownable {
    using SafeERC20 for IERC20;

    constructor(address owner) Ownable(owner) {}

    /**
     * @notice Withdraw tokens from the contract.
     * @param token Token to withdraw.
     * @param amount Amount of tokens to withdraw.
     */
    function withdraw(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(msg.sender, amount);
    }
}
