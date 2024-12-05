//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20Auth } from "../external/interfaces/IERC20Auth.sol";
import { SpokePoolV3Periphery } from "../SpokePoolV3Periphery.sol";

interface SpokePoolV3PeripheryProxyInterface {
    /**
     * @notice Swaps tokens on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param swapToken Address of the token that will be swapped for acrossInputToken.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param exchange Address of the exchange contract to call.
     * @param routerCalldata ABI encoded function data to call on router. Should form a swap of swapToken for
     * enough of acrossInputToken, otherwise this function will revert.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     */
    function swapAndBridge(
        IERC20 swapToken,
        IERC20 acrossInputToken,
        address exchange,
        bytes calldata routerCalldata,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        SpokePoolV3Periphery.DepositData calldata depositData
    ) external;
}

/**
 * @title SpokePoolV3Periphery
 * @notice Contract for performing more complex interactions with an Across spoke pool deployment.
 * @dev Variables which may be immutable are not marked as immutable, nor defined in the constructor, so that this
 * contract may be deployed deterministically at the same address across different networks.
 * @custom:security-contact bugs@across.to
 */
interface SpokePoolV3PeripheryInterface {
    /**
     * @notice Passthrough function to `depositV3()` on the SpokePool contract.
     * @dev Protects the caller from losing their ETH (or other native token) by reverting if the SpokePool address
     * they intended to call does not exist on this chain. Because this contract can be deployed at the same address
     * everywhere callers should be protected even if the transaction is submitted to an unintended network.
     * This contract should only be used for native token deposits, as this problem only exists for native tokens.
     * @param recipient Address to receive funds at on destination chain.
     * @param inputToken Token to lock into this contract to initiate deposit.
     * @param inputAmount Amount of tokens to deposit.
     * @param outputAmount Amount of tokens to receive on destination chain.
     * @param destinationChainId Denotes network where user will receive funds from SpokePool by a relayer.
     * @param quoteTimestamp Timestamp used by relayers to compute this deposit's realizedLPFeePct which is paid
     * to LP pool on HubPool.
     * @param message Arbitrary data that can be used to pass additional information to the recipient along with the tokens.
     * Note: this is intended to be used to pass along instructions for how a contract should use or allocate the tokens.
     * @param exclusiveRelayer Address of the relayer who has exclusive rights to fill this deposit. Can be set to
     * 0x0 if no period is desired. If so, then must set exclusivityParameter to 0.
     * @param exclusivityParameter Timestamp or offset, after which any relayer can fill this deposit. Must set
     * to 0 if exclusiveRelayer is set to 0x0, and vice versa.
     * @param fillDeadline Timestamp after which this deposit can no longer be filled.
     */
    function deposit(
        address recipient,
        address inputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes memory message
    ) external payable;

    /**
     * @notice Swaps tokens on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If msg.value is 0, then this function is only callable by the proxy contract, to protect against
     * approval abuse attacks where a user has set an approval on this contract to spend any ERC20 token.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param swapToken Address of the token that will be swapped for acrossInputToken.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param exchange Address of the exchange contract to call.
     * @param routerCalldata ABI encoded function data to call on router. Should form a swap of swapToken for
     * enough of acrossInputToken, otherwise this function will revert.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     */
    function swapAndBridge(
        IERC20 swapToken,
        IERC20 acrossInputToken,
        address exchange,
        bytes calldata routerCalldata,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        SpokePoolV3Periphery.DepositData calldata depositData
    ) external payable;

    /**
     * @notice Swaps an EIP-2612 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken does not implement `permit` to the specifications of EIP-2612, this function will fail.
     * @param swapToken Address of the token that will be swapped for acrossInputToken.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param exchange Address of the exchange contract to call.
     * @param routerCalldata ABI encoded function data to call on router. Should form a swap of swapToken for
     * enough of acrossInputToken, otherwise this function will revert.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     * @param deadline Deadline before which the permit signature is valid.
     * @param v v of the permit signature.
     * @param r r of the permit signature.
     * @param s s of the permit signature.
     */
    function swapAndBridgeWithPermit(
        IERC20Permit swapToken,
        IERC20 acrossInputToken,
        address exchange,
        bytes calldata routerCalldata,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        SpokePoolV3Periphery.DepositData calldata depositData,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @notice Swaps an EIP-3009 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken does not implement `receiveWithAuthorization` to the specifications of EIP-3009, this call will revert.
     * @param swapToken Address of the token that will be swapped for acrossInputToken.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param exchange Address of the exchange contract to call.
     * @param routerCalldata ABI encoded function data to call on router. Should form a swap of swapToken for
     * enough of acrossInputToken, otherwise this function will revert.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param nonce Unique nonce used in the `receiveWithAuthorization` signature.
     * @param v v of the EIP-3009 signature.
     * @param r r of the EIP-3009 signature.
     * @param s s of the EIP-3009 signature.
     */
    function swapAndBridgeWithAuthorization(
        IERC20Auth swapToken,
        IERC20 acrossInputToken,
        address exchange,
        bytes calldata routerCalldata,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        SpokePoolV3Periphery.DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @notice Deposits an EIP-2612 token Across input token into the Spoke Pool contract.
     * @dev If `acrossInputToken` does not implement `permit` to the specifications of EIP-2612, this function will fail.
     * @param acrossInputToken EIP-2612 compliant token to deposit.
     * @param acrossInputAmount Amount of the input token to deposit.
     * @param depositData Specifies the Across deposit params to send.
     * @param deadline Deadline before which the permit signature is valid.
     * @param v v of the permit signature.
     * @param r r of the permit signature.
     * @param s s of the permit signature.
     */
    function depositWithPermit(
        IERC20Permit acrossInputToken,
        uint256 acrossInputAmount,
        SpokePoolV3Periphery.DepositData calldata depositData,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @notice Deposits an EIP-3009 compliant Across input token into the Spoke Pool contract.
     * @dev If `acrossInputToken` does not implement `receiveWithAuthorization` to the specifications of EIP-3009, this call will revert.
     * @param acrossInputToken EIP-3009 compliant token to deposit.
     * @param acrossInputAmount Amount of the input token to deposit.
     * @param depositData Specifies the Across deposit params to send.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param nonce Unique nonce used in the `receiveWithAuthorization` signature.
     * @param v v of the EIP-3009 signature.
     * @param r r of the EIP-3009 signature.
     * @param s s of the EIP-3009 signature.
     */
    function depositWithAuthorization(
        IERC20Auth acrossInputToken,
        uint256 acrossInputAmount,
        SpokePoolV3Periphery.DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
