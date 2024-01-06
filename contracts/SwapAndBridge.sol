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

// This 1Inch router used to swap USDC on the following networks:
// - Polygon: https://polygonscan.com/address/0x1111111254eeb25477b68fb85ed929f73a960582
// - Optimism: https://optimistic.etherscan.io/address/0x1111111254eeb25477b68fb85ed929f73a960582
// - Arbitrum: https://arbiscan.io/address/0x1111111254eeb25477b68fb85ed929f73a960582
// - Base: https://basescan.org/address/0x1111111254eeb25477b68fb85ed929f73a960582
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

// This is the interface for the USDC.e/USDC V3 pool that the Uniswap Universal Router routes to on the following
// networks:
// - Arbitrum: https://arbiscan.io/address/0x8e295789c9465487074a65b1ae9ce0351172393f
// - Optimism: https://optimistic.etherscan.io/address/0x2ab22ac86b25bd448a4d9dc041bd2384655299c4
// - Polygon: https://polygonscan.com/address/0xd36ec33c8bed5a9f7b6630855f1533455b98a418
// - Base: https://basescan.org/address/0x06959273e9a65433de71f5a452d529544e07ddd0
interface IUniswapV3Pool {
    /// @notice Swap token0 for token1, or token1 for token0
    /// @dev The caller of this method receives a callback in the form of IUniswapV3SwapCallback#uniswapV3SwapCallback
    /// @param recipient The address to receive the output of the swap
    /// @param zeroForOne The direction of the swap, true for token0 to token1, false for token1 to token0
    /// @param amountSpecified The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative)
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this
    /// value after the swap. If one for zero, the price cannot be greater than this value after the swap
    /// @param data Any data to be passed through to the callback
    /// @return amount0 The delta of the balance of token0 of the pool, exact when negative, minimum when positive
    /// @return amount1 The delta of the balance of token1 of the pool, exact when negative, minimum when positive
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    /// @notice The first of the two tokens of the pool, sorted by address
    /// @return The token contract address
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address
    /// @return The token contract address
    function token1() external view returns (address);
}

// This is the interface for the Uniswap UniversalRouter that we can use to propose a more complex set of
// transactions to swap between tokens.
// - Arbitrum: https://arbiscan.io/address/0xec8b0f7ffe3ae75d7ffab09429e3675bb63503e4
// - Optimism: https://optimistic.etherscan.io/address/0xeC8B0F7Ffe3ae75d7FfAb09429e3675bb63503e4
// - Polygon: https://polygonscan.com/address/0x643770e279d5d0733f21d6dc03a8efbabf3255b4
// - Base: https://basescan.org/address/0xeC8B0F7Ffe3ae75d7FfAb09429e3675bb63503e4
interface IUniversalRouter {
    /// @notice Executes encoded commands along with provided inputs. Reverts if deadline has expired.
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    /// @param deadline The deadline by which the transaction must be executed
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

/**
 * @title SwapAndBridge
 * @notice Allows caller to swap a specific on a chain and bridge them via Across atomically.
 */
contract SwapAndBridge is Lockable, MultiCaller {
    using SafeERC20 for IERC20;

    // Across SpokePool we'll submit deposits to with acrossInputToken as the input token.
    USSSpokePoolInterface public immutable spokePool;

    // 1Inch router we'll use to swap swapToken for acrossInputToken.
    I1InchAggregationRouterV5 public immutable oneInchRouter;

    // UniswapV3Pool we'll use to swap swapToken for acrossInputToken.
    IUniswapV3Pool public immutable uniswapV3Pool;

    // Uniswap UniversalRouter we can use to express a more complex swapping route.
    IUniversalRouter public immutable universalRouter;

    // The direction of the UniswapV3 swap, true for token0 to token1, false for token1 to token0
    bool public immutable uniswapSwapZeroForOne;

    // This contract simply enables the caller to swap a token on this chain for another specified one
    // and bridge it as the input token via Across. This simplification is made to make the code
    // easier to reason about and solve a specific use case for Across.
    IERC20 public immutable swapToken;

    // The token that will be bridged via Across as the inputToken.
    IERC20 public immutable acrossInputToken;

    // Params we'll need caller to pass in to specify an Across Deposit. The input token will be swapped into first
    // before submitting a bridge deposit, which is why we don't include the input token amount as it is not known
    // until after the swap.
    struct DepositData {
        // Token received on destination chain.
        address outputToken;
        // Amount of output token to be received by recipient.
        uint256 outputAmount;
        // The account credited with deposit who can submit speedups to the Across deposit.
        address depositor;
        // The account that will receive the output token on the destination chain. If the output token is
        // wrapped native token, then if this is an EOA then they will receive native token on the destination
        // chain and if this is a contract then they will receive an ERC20.
        address recipient;
        // The destination chain identifier.
        uint256 destinationChainid;
        // The account that can exclusively fill the deposit before the exclusivity deadline.
        address exclusiveRelayer;
        // Timestamp of the deposit used by system to charge fees. Must be within short window of time into the past
        // relative to this chain's current time or deposit will revert.
        uint32 quoteTimestamp;
        // The timestamp on the destination chain after which this deposit can no longer be filled.
        uint32 fillDeadline;
        // The timestamp on the destination chain after which anyone can fill the deposit.
        uint32 exclusivityDeadline;
        // Data that is forwarded to the recipient if the recipient is a contract.
        bytes message;
    }

    /****************************************
     *                ERRORS                *
     ****************************************/
    error InvalidToken0Token1();
    error MinimumExpectedInputAmount();
    error LeftoverSrcTokens();

    /**
     * @notice Construct a new SwapAndBridge contract.
     * @param _spokePool Address of the SpokePool contract that we'll submit deposits to.
     * @param _oneInchRouter Address of the 1InchAggregationRouterV5 contract that we'll use to swap tokens.
     * @param _uniswapV3Pool Address of the UniswapV3Pool contract that we'll use to swap tokens.
     * @param _universalRouter Address of the Uniswap UniversalRouter contract that we'll use to swap tokens.
     * @param _swapToken Address of the token that will be swapped for acrossInputToken. Cannot be 0x0
     * @param _acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     */
    constructor(
        USSSpokePoolInterface _spokePool,
        I1InchAggregationRouterV5 _oneInchRouter,
        IUniswapV3Pool _uniswapV3Pool,
        IUniversalRouter _universalRouter,
        IERC20 _swapToken,
        IERC20 _acrossInputToken
    ) {
        spokePool = _spokePool;
        swapToken = _swapToken;
        acrossInputToken = _acrossInputToken;

        // Validate 1InchAggregationRouterV5:
        oneInchRouter = _oneInchRouter;

        // Validate UniversalRouter:
        universalRouter = _universalRouter;

        // Validate UniswapV3Pool:
        uniswapV3Pool = _uniswapV3Pool;
        // - should have token0/token1 equal to swapToken/acrossInputToken.
        if (address(_swapToken) == _uniswapV3Pool.token0()) {
            if (address(_acrossInputToken) != _uniswapV3Pool.token1()) revert InvalidToken0Token1();
        } else if (address(_swapToken) == _uniswapV3Pool.token1()) {
            if (address(_acrossInputToken) != _uniswapV3Pool.token0()) revert InvalidToken0Token1();
        } else {
            revert InvalidToken0Token1();
        }
        // This contract should swap swapToken for acrossInputToken, so set zeroForOne=true if swapToken is token0.
        uniswapSwapZeroForOne = (address(_swapToken) == _uniswapV3Pool.token0());
    }

    /**
     * @notice Swaps tokens on this chain via 1Inch and bridges them via Across atomically. Caller can specify
     * their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
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
            // the caller to pass in extra msg.value to pay for ETH swaps but we do not support such swaps.
        });

        // Swap and run safety checks.
        uint256 srcBalanceBefore = swapToken.balanceOf(address(this));
        uint256 dstBalanceBefore = acrossInputToken.balanceOf(address(this));

        acrossInputToken.safeIncreaseAllowance(address(oneInchRouter), swapTokenAmount);
        oneInchRouter.swap(
            aggregationExecutor,
            swapDescription,
            new bytes(0), // No IERC20Permit.permit needed since we're going to approve 1InchRouter to pull tokens
            // from this contract.
            new bytes(0) // We don't want to execute any extra data on swaps.
        );

        _checkSwapOutputAndDeposit(
            swapTokenAmount,
            srcBalanceBefore,
            dstBalanceBefore,
            minExpectedInputTokenAmount,
            depositData
        );
    }

    /**
     * @notice Swaps tokens on this chain via a UniswapV3Pool and bridges them via Across atomically. Caller can
     * specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     */
    function swapUniswapV3AndBridge(
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData
    ) external nonReentrant {
        // Pull tokens from caller into this contract.
        swapToken.transferFrom(msg.sender, address(this), swapTokenAmount);

        // Swap and run safety checks.
        uint256 srcBalanceBefore = swapToken.balanceOf(address(this));
        uint256 dstBalanceBefore = acrossInputToken.balanceOf(address(this));

        acrossInputToken.safeIncreaseAllowance(address(uniswapV3Pool), swapTokenAmount);
        uniswapV3Pool.swap(
            address(this), // recipient
            uniswapSwapZeroForOne, // zeroForOne: true for token0 to token1, false for token1 to token0
            int256(swapTokenAmount), // amountSpecified: The amount token0 to swap
            0, // sqrtPriceLimitX96: The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this.
            // Set to 0 to make inactive as we'll check the returned output in the next step.
            new bytes(0) // We don't want to execute any extra data on swaps.
        );

        _checkSwapOutputAndDeposit(
            swapTokenAmount,
            srcBalanceBefore,
            dstBalanceBefore,
            minExpectedInputTokenAmount,
            depositData
        );
    }

    /**
     * @notice Swaps tokens on this chain via a UniversalRouter and bridges them via Across atomically. Caller can
     * specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param commands A set of concatenated commands to send to the UniversalRouter, each 1 byte in length.
     * @param inputs An array of byte strings containing abi encoded inputs for each command.
     * @param deadline The deadline by which the transaction must be executed.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     */
    function swapUniversalRouter(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData
    ) external nonReentrant {
        // Pull tokens from caller into this contract.
        swapToken.transferFrom(msg.sender, address(this), swapTokenAmount);

        // Swap and run safety checks.
        uint256 srcBalanceBefore = swapToken.balanceOf(address(this));
        uint256 dstBalanceBefore = acrossInputToken.balanceOf(address(this));

        acrossInputToken.safeIncreaseAllowance(address(uniswapV3Pool), swapTokenAmount);
        universalRouter.execute(commands, inputs, deadline);

        _checkSwapOutputAndDeposit(
            swapTokenAmount,
            srcBalanceBefore,
            dstBalanceBefore,
            minExpectedInputTokenAmount,
            depositData
        );
    }

    /**
     * @notice Check that the swap returned enough tokens to submit an Across deposit with and then submit the deposit.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of acrossInputToken.
     * @param swapTokenBalanceBefore Balance of swapToken before swap.
     * @param inputTokenBalanceBefore Amount of Across input token we held before swap
     * @param minExpectedInputTokenAmount Minimum amount of received acrossInputToken that we'll bridge
     **/
    function _checkSwapOutputAndDeposit(
        uint256 swapTokenAmount,
        uint256 swapTokenBalanceBefore,
        uint256 inputTokenBalanceBefore,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData
    ) internal {
        // Sanity check that we received as many tokens as we require:
        uint256 returnAmount = acrossInputToken.balanceOf(address(this)) - inputTokenBalanceBefore;
        // Sanity check that received amount from swap is enough to submit Across deposit with.
        if (returnAmount < minExpectedInputTokenAmount) revert MinimumExpectedInputAmount();
        // Sanity check that we don't have any leftover swap tokens that would be locked in this contract (i.e. check
        // that we weren't partial filled).
        if (swapTokenBalanceBefore - swapToken.balanceOf(address(this)) != swapTokenAmount) revert LeftoverSrcTokens();

        // Deposit the swapped tokens into Across and bridge them using remainder of input params.
        acrossInputToken.safeIncreaseAllowance(address(spokePool), returnAmount);
        spokePool.depositUSS(
            depositData.depositor,
            depositData.recipient,
            address(acrossInputToken), // input token
            depositData.outputToken, // output token
            returnAmount, // input amount.
            depositData.outputAmount, // output amount
            depositData.destinationChainid,
            depositData.exclusiveRelayer,
            depositData.quoteTimestamp,
            depositData.fillDeadline,
            depositData.exclusivityDeadline,
            depositData.message
        );
    }
}
