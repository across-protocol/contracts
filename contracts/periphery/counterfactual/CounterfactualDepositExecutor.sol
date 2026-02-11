// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";

/**
 * @notice Extended interface to access SpokePool state
 */
interface ISpokePoolExtended is V3SpokePoolInterface {
    function numberOfDeposits() external view returns (uint32);
}

/**
 * @title CounterfactualDepositExecutor
 * @notice Implementation contract for counterfactual deposits, deployed as EIP-1167 clones with immutable args
 * @dev The factory deploys minimal proxies (clones) of this contract using OZ Clones.cloneDeterministicWithImmutableArgs.
 * Route parameters are appended to the clone bytecode and read via Clones.fetchCloneArgs.
 */
contract CounterfactualDepositExecutor {
    using SafeERC20 for IERC20;

    /// @notice Route parameters stored as immutable args in clone bytecode
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
     * @dev Called on EIP-1167 clone instances; reads route params from clone immutable args
     * @param quote Signed deposit quote containing all deposit parameters
     * @param signature Signature from authorized quoteSigner
     */
    function executeDeposit(
        ICounterfactualDepositFactory.DepositQuote calldata quote,
        bytes calldata signature
    ) external {
        // Get route parameters from clone immutable args
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
            revert ICounterfactualDepositFactory.GasFeeTooHigh();
        }

        // Get actual token balance
        address inputTokenAddr = address(uint160(uint256(params.inputToken)));
        uint256 balance = IERC20(inputTokenAddr).balanceOf(address(this));

        // Verify sufficient balance
        if (balance < quote.inputAmount) revert ICounterfactualDepositFactory.InsufficientBalance();

        // Approve SpokePool for inputAmount
        IERC20(inputTokenAddr).safeIncreaseAllowance(spokePool, quote.inputAmount);

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
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Gets route parameters from clone immutable args appended to bytecode
     * @dev Uses OZ Clones.fetchCloneArgs to read args set during cloneDeterministicWithImmutableArgs
     * @return params RouteParams struct containing all route-specific parameters
     */
    function _getRouteParams() internal view returns (RouteParams memory params) {
        bytes memory args = Clones.fetchCloneArgs(address(this));
        (
            bytes32 inputToken,
            bytes32 outputToken,
            uint256 destinationChainId,
            bytes32 recipient,
            uint256 maxGasFee,
            uint256 maxCapitalFee,
            bytes memory message
        ) = abi.decode(args, (bytes32, bytes32, uint256, bytes32, uint256, uint256, bytes));
        return RouteParams(inputToken, outputToken, destinationChainId, recipient, message, maxGasFee, maxCapitalFee);
    }
}
