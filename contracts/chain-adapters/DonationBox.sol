// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Users can donate tokens to this contract that only the owner can withdraw.
 * @dev This contract is designed to be used as a convenience for the owner to store funds to pay for
 * future transactions, such as donating custom gas tokens to pay for future retryable ticket messages
 * to be sent via the Arbitrum_Adapter.
 * @custom:security-contact bugs@across.to
 */
contract DonationBox is Ownable {
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
