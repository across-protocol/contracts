// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Contract to fund custom gas token fees when using the Arbitrum_CustomGasToken_Adapter
 * to send messages and tokens from Ethereum to an Arbitrum L2 that uses custom gas tokens
 * @dev https://docs.arbitrum.io/launch-orbit-chain/how-tos/use-a-custom-gas-token
 */
contract Arbitrum_CustomGasToken_Funder is Ownable {
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
