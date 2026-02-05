// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";

/**
 * @notice Extended interface to access SpokePool state
 */
interface ISpokePoolExtended is V3SpokePoolInterface {
    function numberOfDeposits() external view returns (uint32);
}
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";

/**
 * @title CounterfactualDepositExecutor
 * @notice Singleton implementation contract containing execution logic for counterfactual deposits
 * @dev This contract is called via delegatecall from CounterfactualDeposit proxies
 * It contains the logic for executing deposits and admin withdrawals
 */
contract CounterfactualDepositExecutor {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @notice Executes a deposit with a signed quote
     * @dev This function is called via delegatecall, so it operates in the proxy's context
     * @param quote Signed deposit quote containing all deposit parameters
     * @param signature Signature from authorized quoteSigner
     */
    function executeDeposit(
        ICounterfactualDepositFactory.DepositQuote calldata quote,
        bytes calldata signature
    ) external {
        // Get immutable parameters from proxy context
        address factory = _getFactory();
        address spokePool = _getSpokePool();
        bytes32 inputToken = _getInputToken();
        bytes32 outputToken = _getOutputToken();
        uint256 destinationChainId = _getDestinationChainId();
        bytes32 recipient = _getRecipient();

        // Verify quote is for this specific deposit address
        if (quote.depositAddress != address(this)) revert ICounterfactualDepositFactory.WrongDepositAddress();

        // Verify quote hasn't expired
        if (block.timestamp > quote.deadline) revert ICounterfactualDepositFactory.QuoteExpired();

        // Verify signature via factory
        if (!ICounterfactualDepositFactory(factory).verifyQuote(quote, signature)) {
            revert ICounterfactualDepositFactory.InvalidSignature();
        }

        // Get actual token balance
        address inputTokenAddr = address(uint160(uint256(inputToken)));
        uint256 balance = IERC20Upgradeable(inputTokenAddr).balanceOf(address(this));

        // Verify sufficient balance
        if (balance < quote.inputAmount) revert ICounterfactualDepositFactory.InsufficientBalance();

        // Approve SpokePool for inputAmount
        IERC20Upgradeable(inputTokenAddr).safeIncreaseAllowance(spokePool, quote.inputAmount);

        // Get depositId before executing (will be incremented by deposit)
        uint256 depositId = ISpokePoolExtended(spokePool).numberOfDeposits();

        // Execute deposit on SpokePool
        // Use address(this) as depositor so refunds come back to this contract, not the caller
        V3SpokePoolInterface(spokePool).deposit(
            bytes32(uint256(uint160(address(this)))), // depositor (this contract - refunds come here)
            recipient, // recipient on destination chain
            inputToken, // inputToken
            outputToken, // outputToken
            quote.inputAmount, // inputAmount
            quote.outputAmount, // outputAmount
            destinationChainId, // destinationChainId
            quote.exclusiveRelayer, // exclusiveRelayer
            quote.quoteTimestamp, // quoteTimestamp
            quote.fillDeadline, // fillDeadline
            quote.exclusivityParameter, // exclusivityDeadline
            quote.message // message
        );

        // Emit event for indexing
        emit ICounterfactualDepositFactory.DepositExecuted(
            address(this),
            quote.inputAmount,
            quote.outputAmount,
            depositId
        );
    }

    /**
     * @notice Allows admin to withdraw tokens from the deposit contract
     * @dev Used for refunds or recovering wrongly sent tokens
     * @param token Token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function adminWithdraw(address token, address to, uint256 amount) external {
        // Get factory from proxy context
        address factory = _getFactory();

        // Verify caller is admin
        if (msg.sender != ICounterfactualDepositFactory(factory).admin()) {
            revert ICounterfactualDepositFactory.Unauthorized();
        }

        // Transfer tokens
        IERC20Upgradeable(token).safeTransfer(to, amount);
    }

    /**
     * @notice Gets factory address from appended calldata
     * @dev The proxy appends 192 bytes of immutable parameters to the end of calldata
     * Format: factory(32) + spokePool(32) + inputToken(32) + outputToken(32) + destinationChainId(32) + recipient(32)
     * When called via delegatecall, we read these from the extended calldata
     */
    function _getFactory() internal pure returns (address factory) {
        assembly {
            factory := calldataload(sub(calldatasize(), 192))
        }
    }

    function _getSpokePool() internal pure returns (address spokePool) {
        assembly {
            spokePool := calldataload(sub(calldatasize(), 160))
        }
    }

    function _getInputToken() internal pure returns (bytes32 inputToken) {
        assembly {
            inputToken := calldataload(sub(calldatasize(), 128))
        }
    }

    function _getOutputToken() internal pure returns (bytes32 outputToken) {
        assembly {
            outputToken := calldataload(sub(calldatasize(), 96))
        }
    }

    function _getDestinationChainId() internal pure returns (uint256 destinationChainId) {
        assembly {
            destinationChainId := calldataload(sub(calldatasize(), 64))
        }
    }

    function _getRecipient() internal pure returns (bytes32 recipient) {
        assembly {
            recipient := calldataload(sub(calldatasize(), 32))
        }
    }
}
