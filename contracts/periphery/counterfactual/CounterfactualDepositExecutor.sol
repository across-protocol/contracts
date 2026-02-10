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

    /// @notice Route parameters passed from proxy via calldata
    struct RouteParams {
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 destinationChainId;
        bytes32 recipient;
        bytes message;
        uint256 maxGasFee;
        uint256 maxCapitalFee;
    }

    /// @notice Factory contract (immutable, same for all deposits on this chain)
    address public immutable factory;

    /// @notice SpokePool contract (immutable, same for all deposits on this chain)
    address public immutable spokePool;

    /**
     * @notice Constructs the executor with chain-specific constants
     * @param _factory Factory contract address
     * @param _spokePool SpokePool contract address
     */
    constructor(address _factory, address _spokePool) {
        factory = _factory;
        spokePool = _spokePool;
    }

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
        // Get route parameters from appended calldata (proxy passes these)
        RouteParams memory params = _getRouteParams();

        // Verify quote is for this specific deposit address
        if (quote.depositAddress != address(this)) revert ICounterfactualDepositFactory.WrongDepositAddress();

        // Verify quote hasn't expired
        if (block.timestamp > quote.deadline) revert ICounterfactualDepositFactory.QuoteExpired();

        // Verify signature via factory (immutable)
        if (!ICounterfactualDepositFactory(factory).verifyQuote(quote, signature)) {
            revert ICounterfactualDepositFactory.InvalidSignature();
        }

        // Validate fees to protect user from bad quotes
        // Total allowed fee is the sum of absolute gas fee + percentage-based capital fee
        uint256 actualFee = quote.inputAmount - quote.outputAmount;
        uint256 maxAllowedFee = params.maxGasFee + ((quote.inputAmount * params.maxCapitalFee) / 10000);

        if (actualFee > maxAllowedFee) {
            revert ICounterfactualDepositFactory.FeeTooHigh();
        }

        // Get actual token balance
        address inputTokenAddr = address(uint160(uint256(params.inputToken)));
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
            params.recipient, // recipient on destination chain
            params.inputToken, // inputToken
            params.outputToken, // outputToken
            quote.inputAmount, // inputAmount
            quote.outputAmount, // outputAmount
            params.destinationChainId, // destinationChainId
            quote.exclusiveRelayer, // exclusiveRelayer
            quote.quoteTimestamp, // quoteTimestamp
            quote.fillDeadline, // fillDeadline
            quote.exclusivityParameter, // exclusivityDeadline
            params.message // message (from route params, not quote)
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
        // Verify caller is admin (factory is immutable)
        if (msg.sender != ICounterfactualDepositFactory(factory).admin()) {
            revert ICounterfactualDepositFactory.Unauthorized();
        }

        // Transfer tokens
        IERC20Upgradeable(token).safeTransfer(to, amount);
    }

    /**
     * @notice Gets route parameters from appended calldata
     * @dev The proxy appends: [ABI-encoded RouteParams][uint256 original calldata size]
     * ABI encoding format: inputToken(32) + outputToken(32) + destinationChainId(32) + recipient(32) +
     *                      messageOffset(32) + maxGasFee(32) + maxCapitalFee(32) +
     *                      messageLength(32) + messageData(variable)
     * @return params RouteParams struct containing all route-specific parameters
     */
    function _getRouteParams() internal pure returns (RouteParams memory params) {
        assembly {
            // Read original calldata size from the last 32 bytes
            let originalSize := calldataload(sub(calldatasize(), 32))

            // Route params start at originalSize
            let offset := originalSize

            // Read fixed-size parameters
            let _inputToken := calldataload(offset) // offset 0
            let _outputToken := calldataload(add(offset, 32)) // offset 32
            let _destinationChainId := calldataload(add(offset, 64)) // offset 64
            let _recipient := calldataload(add(offset, 96)) // offset 96

            // Message is at offset 128 (the offset value) + its position
            // The value at offset 128 tells us where the message data starts (relative to start of encoded data)
            let messageDataOffset := calldataload(add(offset, 128)) // This is typically 224 (0xe0) with fees
            let messageStart := add(offset, messageDataOffset)
            let messageLength := calldataload(messageStart)
            let messageDataStart := add(messageStart, 32)

            // Read fee parameters (after first 5 params)
            let _maxGasFee := calldataload(add(offset, 160)) // offset 160
            let _maxCapitalFee := calldataload(add(offset, 192)) // offset 192

            // Allocate memory for the struct
            params := mload(0x40)

            // Store fixed-size fields
            mstore(params, _inputToken) // offset 0
            mstore(add(params, 0x20), _outputToken) // offset 32
            mstore(add(params, 0x40), _destinationChainId) // offset 64
            mstore(add(params, 0x60), _recipient) // offset 96

            // Allocate memory for the message bytes (after the struct fields + fee fields)
            let messagePtr := add(params, 0xe0) // After all fixed fields (7*32 = 224)

            // Store pointer to message in the struct (offset 128 in struct)
            mstore(add(params, 0x80), messagePtr)

            // Store fee parameters
            mstore(add(params, 0xa0), _maxGasFee) // offset 160
            mstore(add(params, 0xc0), _maxCapitalFee) // offset 192

            // Store message length at the message pointer location
            mstore(messagePtr, messageLength)

            // Copy message data
            calldatacopy(add(messagePtr, 0x20), messageDataStart, messageLength)

            // Update free memory pointer to after the message data
            mstore(0x40, add(add(messagePtr, 0x20), messageLength))
        }
    }
}
