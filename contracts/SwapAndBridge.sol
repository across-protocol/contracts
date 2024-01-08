//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/USSSpokePoolInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Lockable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";

/**
 * @title SwapAndBridge
 * @notice Allows caller to swap between two specified tokens on a chain before bridging the received token
 * via Across atomically. Provides safety checks post-swap and before-deposit.
 */
contract SwapAndBridge is Lockable, MultiCaller {
    using SafeERC20 for IERC20;

    // Across SpokePool we'll submit deposits to with acrossInputToken as the input token.
    USSSpokePoolInterface public immutable spokePool;

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
    error MinimumExpectedInputAmount();
    error LeftoverSrcTokens();

    /**
     * @notice Construct a new SwapAndBridge contract.
     * @param _spokePool Address of the SpokePool contract that we'll submit deposits to.
     * @param _swapToken Address of the token that will be swapped for acrossInputToken. Cannot be 0x0
     * @param _acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     */
    constructor(
        USSSpokePoolInterface _spokePool,
        IERC20 _swapToken,
        IERC20 _acrossInputToken
    ) {
        spokePool = _spokePool;
        swapToken = _swapToken;
        acrossInputToken = _acrossInputToken;
    }

    /**
     * @notice Swaps tokens on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param routerCalldata ABI encoded function data to call on router. Should form a swap of swapToken for
     * enough of acrossInputToken, otherwise this function will revert.
     * @param router Address of router to call.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     */
    function swapAndBridge(
        bytes calldata routerCalldata,
        address router,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData
    ) external nonReentrant {
        // Pull tokens from caller into this contract.
        swapToken.transferFrom(msg.sender, address(this), swapTokenAmount);
        // Swap and run safety checks.
        uint256 srcBalanceBefore = swapToken.balanceOf(address(this));
        uint256 dstBalanceBefore = acrossInputToken.balanceOf(address(this));

        acrossInputToken.safeIncreaseAllowance(router, swapTokenAmount);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory result) = router.call(routerCalldata);
        require(success, string(result));

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

/**
 * @title UniversalSwapAndBridge
 * @notice Allows caller to swap between any two tokens specified at run-time on a chain before
 * bridging the received token via Across atomically. Provides safety checks post-swap and before-deposit.
 */
contract UniversalSwapAndBridge is Lockable, MultiCaller {
    using SafeERC20 for IERC20;

    // Across SpokePool we'll submit deposits to with acrossInputToken as the input token.
    USSSpokePoolInterface public immutable spokePool;

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
    error MinimumExpectedInputAmount();
    error LeftoverSrcTokens();

    /**
     * @notice Construct a new UniversalSwapAndBridge contract.
     * @param _spokePool Address of the SpokePool contract that we'll submit deposits to.
     */
    constructor(USSSpokePoolInterface _spokePool) {
        spokePool = _spokePool;
    }

    /**
     * @notice Swaps tokens on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param swapToken Address of the token that will be swapped for acrossInputToken.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param routerCalldata ABI encoded function data to call on router. Should form a swap of swapToken for
     * enough of acrossInputToken, otherwise this function will revert.
     * @param router Address of router to call.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     */
    function swapAndBridge(
        IERC20 swapToken,
        IERC20 acrossInputToken,
        bytes calldata routerCalldata,
        address router,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData
    ) external nonReentrant {
        // Pull tokens from caller into this contract.
        swapToken.transferFrom(msg.sender, address(this), swapTokenAmount);
        // Swap and run safety checks.
        uint256 srcBalanceBefore = swapToken.balanceOf(address(this));
        uint256 dstBalanceBefore = acrossInputToken.balanceOf(address(this));

        acrossInputToken.safeIncreaseAllowance(router, swapTokenAmount);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory result) = router.call(routerCalldata);
        require(success, string(result));

        _checkSwapOutputAndDeposit(
            swapToken,
            acrossInputToken,
            swapTokenAmount,
            srcBalanceBefore,
            dstBalanceBefore,
            minExpectedInputTokenAmount,
            depositData
        );
    }

    /**
     * @notice Check that the swap returned enough tokens to submit an Across deposit with and then submit the deposit.
     * @param swapToken Address of the token that will be swapped for acrossInputToken.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of acrossInputToken.
     * @param swapTokenBalanceBefore Balance of swapToken before swap.
     * @param inputTokenBalanceBefore Amount of Across input token we held before swap
     * @param minExpectedInputTokenAmount Minimum amount of received acrossInputToken that we'll bridge
     **/
    function _checkSwapOutputAndDeposit(
        IERC20 swapToken,
        IERC20 acrossInputToken,
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
