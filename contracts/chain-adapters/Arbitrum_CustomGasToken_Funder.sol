// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Arbitrum_CustomGasToken_Funder is Ownable {
    using SafeERC20 for IERC20;

    /**
     * @notice Withdraw tokens from the contract.
     * @dev Only callable by owner, which should be set to the HubPool
     * so that it can use these funds to pay for relaying messages to
     * an Arbitrum L2 that uses custom gas tokens as the L1 payment currency,
     * via the Arbitrum_CustomGasToken_Adapter.
     * @param token Token to withdraw.
     * @param amount Amount of tokens to withdraw.
     */
    function withdraw(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(msg.sender, amount);
    }
}
