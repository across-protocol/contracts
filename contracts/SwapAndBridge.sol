//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/USSSpokePoolInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Lockable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";

/// @title Interface for making arbitrary calls during swap
interface IAggregationExecutor {
    /// @notice propagates information about original msg.sender and executes arbitrary data
    function execute(address msgSender) external payable; // 0x4b64e492
}

// Grabbed from source code of Optimism V5 router:
// - readable source: https://vscode.blockscan.com/optimism/0x1111111254eeb25477b68fb85ed929f73a960582
// This 1Inch router used to swap USDC on the following networks:
// - Polygon: https://polygonscan.com/address/0x1111111254eeb25477b68fb85ed929f73a960582#code
// - Optimism: https://optimistic.etherscan.io/address/0x1111111254eeb25477b68fb85ed929f73a960582#code
// - Arbitrum: https://arbiscan.io/address/0x1111111254eeb25477b68fb85ed929f73a960582
interface I1InchAggregationRouterV5 {
    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    /**
    /// @notice Performs a swap, delegating all calls encoded in `data` to `executor`.
    /// @dev router keeps 1 wei of every token on the contract balance for gas optimisations reasons. 
    /// This affects first swap of every token by leaving 1 wei on the contract.
    /// @param executor Aggregation executor that executes calls described in `data`
    /// @param desc Swap description
    /// @param permit Should contain valid permit that can be used in `IERC20Permit.permit` calls.
    /// @param data Encoded calls that `caller` should execute in between of swaps
    /// @return returnAmount Resulting token amount
    /// @return spentAmount Source token amount     
    */
    function swap(
        IAggregationExecutor executor,
        SwapDescription calldata desc,
        bytes calldata permit,
        bytes calldata data
    ) external payable returns (uint256 returnAmount, uint256 spentAmount);
}

/**
 * @title SwapAndBridge
 * @notice Allows caller to swap a specific on a chain and bridge them via Across atomically.
 */
contract SwapAndBridge is Lockable, MultiCaller {
    using SafeERC20 for IERC20;

    USSSpokePoolInterface public immutable spokePool;
    I1InchAggregationRouterV5 public immutable oneInchRouter;

    // This contract simply enables the caller to swap a token on this chain for another specified one
    // and bridge it as the input token via Across. This simplification is made to make the code
    // easier to reason about and solve a specific use case for Across.
    IERC20 public immutable swapToken;
    // The token that will be bridged via Across as the inputToken.
    IERC20 public immutable acrossInputToken;

    event SwapAndBridge1Inch(
        I1InchAggregationRouterV5.SwapDescription swapDescription,
        IAggregationExecutor aggregationExecutor
    );

    // Params we'll need caller to pass in to specify an Across Deposit. The input token will be swapped into first
    // before submitting a bridge deposit, which is why we don't include the input token amount as it is not known
    // until after the swap.
    struct DepositData {
        address outputToken;
        uint256 outputAmount;
        address depositor;
        address recipient;
        uint256 destinationChainid;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
    }

    constructor(
        USSSpokePoolInterface _spokePool,
        I1InchAggregationRouterV5 _oneInchRouter,
        IERC20 _swapToken,
        IERC20 _acrossInputToken
    ) {
        spokePool = _spokePool;
        oneInchRouter = _oneInchRouter;
        // 1InchRouter lets caller swap native ETH into an ERC20 and has special logic to handle it
        // so we explicitly remove this case to reduce complexity.
        require(address(_swapToken) != address(0), "eth unsupported");
        swapToken = _swapToken;
        acrossInputToken = _acrossInputToken;
    }

    /**
     * @notice Swaps tokens on this chain via 1Inch and bridges them via Across atomically. Caller can fully specify
     * their slippage tolerance for the swap and Across deposit params.
     * @param aggregationExecutor Address of 1inch contract that executes calls described in `oneInchData`.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     */
    function swap1InchAndBridge(
        IAggregationExecutor aggregationExecutor,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData
    ) external nonReentrant {
        // Pull tokens from caller into this contract.
        swapToken.transferFrom(msg.sender, address(this), swapTokenAmount);

        // Craft 1Inch swap arguments to swap `swapToken` for `acrossInputToken` using this contract as the recipient
        // of the swap.
        I1InchAggregationRouterV5.SwapDescription memory swapDescription = I1InchAggregationRouterV5.SwapDescription({
            srcToken: swapToken,
            dstToken: acrossInputToken,
            srcReceiver: payable(address(this)),
            dstReceiver: payable(address(this)),
            amount: swapTokenAmount,
            minReturnAmount: minExpectedInputTokenAmount,
            flags: 0 // By setting flags=0x0, we're telling 1InchRouter that we don't want
            // partial fills where our swapTokenAmount is not fully used. The other flag we could set would allow
            // the caller to pass in extra msg.value to pay for ETH swaps but we don't support ETH swaps.
        });

        // Swap and run safety checks.
        uint256 srcBalanceBefore = swapToken.balanceOf(address(this));
        uint256 dstBalanceBefore = acrossInputToken.balanceOf(address(this));

        acrossInputToken.safeIncreaseAllowance(address(oneInchRouter), swapTokenAmount);
        (uint256 returnAmount, ) = oneInchRouter.swap(
            aggregationExecutor,
            swapDescription,
            new bytes(0), // No IERC20Permit.permit needed since we're going to approve 1InchRouter to pull tokens
            // from this contract.
            new bytes(0) // We don't want to execute any extra data on swaps.
        );

        // Sanity check that we received exactly as much as the oneInchRouter said we did.
        require(returnAmount == acrossInputToken.balanceOf(address(this)) - dstBalanceBefore, "return amount");
        // Sanity check that received amount from swap is enough to submit Across deposit with.
        require(returnAmount >= minExpectedInputTokenAmount, "min expected input amount");
        // Sanity check that we don't have any leftover swap tokens that would be locked in this contract (i.e. check
        // that we weren't partial filled).
        require(
            srcBalanceBefore - IERC20(swapToken).balanceOf(address(this)) == swapTokenAmount,
            "leftover src tokens"
        );

        // Deposit the swapped tokens into Across and bridge them using remainder of input params.
        acrossInputToken.safeIncreaseAllowance(address(spokePool), returnAmount);
        spokePool.depositUSS(
            depositData.depositor,
            depositData.recipient,
            address(acrossInputToken), // input token
            depositData.outputToken, // output token
            returnAmount, // input amount. Note: this is the amount we received from the swap and checked its value
            // above.
            depositData.outputAmount, // output amount
            depositData.destinationChainid,
            depositData.exclusiveRelayer,
            depositData.quoteTimestamp,
            depositData.fillDeadline,
            depositData.exclusivityDeadline,
            depositData.message
        );

        emit SwapAndBridge1Inch(swapDescription, aggregationExecutor);
    }
}
