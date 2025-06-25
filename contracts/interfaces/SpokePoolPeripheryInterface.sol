//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IPermit2 } from "../external/interfaces/IPermit2.sol";

/**
 * @title SpokePoolPeriphery
 * @notice Contract for performing more complex interactions with an Across spoke pool deployment.
 * @custom:security-contact bugs@across.to
 */
interface SpokePoolPeripheryInterface {
    // Enum describing the method of transferring tokens to an exchange.
    enum TransferType {
        // Approve the exchange so that it may transfer tokens from this contract.
        Approval, // 0
        // Transfer tokens to the exchange before calling it in this contract.
        Transfer, // 1
        // Approve the exchange by authorizing a transfer with Permit2.
        Permit2Approval // 2
    }

    // Submission fees can be set by user to pay whoever submits the transaction in a gasless flow.
    // These are assumed to be in the same currency that is input into the contract.
    struct Fees {
        // Amount of fees to pay recipient for submitting transaction.
        uint256 amount;
        // Recipient of fees amount.
        address recipient;
    }

    // Params we'll need caller to pass in to specify an Across Deposit. The input token will be swapped into first
    // before submitting a bridge deposit, which is why we don't include the input token amount as it is not known
    // until after the swap.
    struct BaseDepositData {
        // Token deposited on origin chain.
        address inputToken;
        // Token received on destination chain.
        bytes32 outputToken;
        // Amount of output token to be received by recipient.
        uint256 outputAmount;
        // The account credited with deposit who can submit speedups to the Across deposit.
        address depositor;
        // The account that will receive the output token on the destination chain. If the output token is
        // wrapped native token, then if this is an EOA then they will receive native token on the destination
        // chain and if this is a contract then they will receive an ERC20.
        bytes32 recipient;
        // The destination chain identifier.
        uint256 destinationChainId;
        // The account that can exclusively fill the deposit before the exclusivity parameter.
        bytes32 exclusiveRelayer;
        // Timestamp of the deposit used by system to charge fees. Must be within short window of time into the past
        // relative to this chain's current time or deposit will revert.
        uint32 quoteTimestamp;
        // The timestamp on the destination chain after which this deposit can no longer be filled.
        uint32 fillDeadline;
        // The timestamp or offset on the destination chain after which anyone can fill the deposit. A detailed description on
        // how the parameter is interpreted by the V3 spoke pool can be found at https://github.com/across-protocol/contracts/blob/fa67f5e97eabade68c67127f2261c2d44d9b007e/contracts/SpokePool.sol#L476
        uint32 exclusivityParameter;
        // Data that is forwarded to the recipient if the recipient is a contract.
        bytes message;
    }

    // Minimum amount of parameters needed to perform a swap on an exchange specified. We include information beyond just the router calldata
    // and exchange address so that we may ensure that the swap was performed properly.
    struct SwapAndDepositData {
        // Amount of fees to pay for submitting transaction. Unused in gasful flows.
        Fees submissionFees;
        // Deposit data to use when interacting with the Across spoke pool.
        BaseDepositData depositData;
        // Token to swap.
        address swapToken;
        // Address of the exchange to use in the swap.
        address exchange;
        // Method of transferring tokens to the exchange.
        TransferType transferType;
        // Amount of the token to swap on the exchange.
        uint256 swapTokenAmount;
        // Minimum output amount of the exchange, and, by extension, the minimum required amount to deposit into an Across spoke pool.
        uint256 minExpectedInputTokenAmount;
        // The calldata to use when calling the exchange.
        bytes routerCalldata;
        // When enabled (true), if the swap returns more tokens than minExpectedInputTokenAmount,
        // the outputAmount will be increased proportionally.
        // When disabled (false), the original outputAmount is used regardless of how many tokens are returned.
        bool enableProportionalAdjustment;
        // Address of the SpokePool to use for depositing tokens after swap.
        address spokePool;
        // User nonce to prevent replay attacks.
        uint256 nonce;
    }

    // Extended deposit data to be used specifically for signing off on periphery deposits.
    struct DepositData {
        // Amount of fees to pay for submitting transaction. Unused in gasful flows.
        Fees submissionFees;
        // Deposit data describing the parameters for the V3 Across deposit.
        BaseDepositData baseDepositData;
        // The precise input amount to deposit into the spoke pool.
        uint256 inputAmount;
        // Address of the SpokePool to use for depositing tokens.
        address spokePool;
        // User nonce to prevent replay attacks.
        uint256 nonce;
    }

    /**
     * @notice Passthrough function to `depositV3()` on the SpokePool contract for native token deposits.
     * @dev Protects the caller from losing their ETH (or other native token) by reverting if the SpokePool address
     * they intended to call does not exist on this chain. Because this contract can be deployed at the same address
     * everywhere callers should be protected even if the transaction is submitted to an unintended network.
     * This contract should only be used for native token deposits, as this problem only exists for native tokens.
     * @param recipient Address (as bytes32) to receive funds on destination chain.
     * @param inputToken Token to lock into this contract to initiate deposit.
     * @param inputAmount Amount of tokens to deposit.
     * @param outputAmount Amount of tokens to receive on destination chain.
     * @param destinationChainId Denotes network where user will receive funds from SpokePool by a relayer.
     * @param quoteTimestamp Timestamp used by relayers to compute this deposit's realizedLPFeePct which is paid
     * to LP pool on HubPool.
     * @param message Arbitrary data that can be used to pass additional information to the recipient along with the tokens.
     * Note: this is intended to be used to pass along instructions for how a contract should use or allocate the tokens.
     * @param exclusiveRelayer Address (as bytes32) of the relayer who has exclusive rights to fill this deposit. Can be set to
     * 0x0 if no period is desired. If so, then must set exclusivityParameter to 0.
     * @param exclusivityParameter Timestamp or offset, after which any relayer can fill this deposit. Must set
     * to 0 if exclusiveRelayer is set to 0x0, and vice versa.
     * @param fillDeadline Timestamp after which this deposit can no longer be filled.
     */
    function depositNative(
        address spokePool,
        bytes32 recipient,
        address inputToken,
        uint256 inputAmount,
        bytes32 outputToken,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes memory message
    ) external payable;

    /**
     * @notice Swaps tokens on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If msg.value is sent, the swapToken in swapAndDepositData must implement the WETH9 interface for wrapping native tokens.
     * @param swapAndDepositData Specifies the data needed to perform a swap on a generic exchange.
     */
    function swapAndBridge(SwapAndDepositData calldata swapAndDepositData) external payable;

    /**
     * @notice Swaps an EIP-2612 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If the swapToken does not implement `permit` to the specifications of EIP-2612, the permit call result will be ignored and the function will continue.
     * @dev If the swapToken in swapData does not implement `permit` to the specifications of EIP-2612, this function will fail.
     * @dev The nonce for the swapAndDepositData signature must be retrieved from permitNonces(signatureOwner).
     * @dev Design Decision: We use separate nonce tracking for permit-based functions versus
     * receiveWithAuthorization-based functions, which creates a theoretical replay attack that we think is
     * incredibly unlikely because this would require:
     * 1. A token implementing both ERC-2612 and ERC-3009
     * 2. A user using the same nonces for swapAndBridgeWithPermit and for swapAndBridgeWithAuthorization
     * 3. Issuing these signatures within a short amount of time (limited by fillDeadlineBuffer)
     * @param signatureOwner The owner of the permit signature and swapAndDepositData signature. Assumed to be the depositor for the Across spoke pool.
     * @param swapAndDepositData Specifies the params we need to perform a swap on a generic exchange.
     * @param deadline Deadline before which the permit signature is valid.
     * @param permitSignature Permit signature encoded as (bytes32 r, bytes32 s, uint8 v).
     * @param swapAndDepositDataSignature The signature against the input swapAndDepositData encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function swapAndBridgeWithPermit(
        address signatureOwner,
        SwapAndDepositData calldata swapAndDepositData,
        uint256 deadline,
        bytes calldata permitSignature,
        bytes calldata swapAndDepositDataSignature
    ) external;

    /**
     * @notice Uses permit2 to transfer tokens from a user before swapping a token on this chain via specified router and submitting an Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev This function assumes the caller has properly set an allowance for the permit2 contract on this network.
     * @dev This function assumes that the amount of token to be swapped is equal to the amount of the token to be received from permit2.
     * @param signatureOwner The owner of the permit2 signature and depositor for the Across spoke pool.
     * @param swapAndDepositData Specifies the params we need to perform a swap on a generic exchange.
     * @param permit The permit data signed over by the owner.
     * @param signature The permit2 signature to verify against the deposit data.
     */
    function swapAndBridgeWithPermit2(
        address signatureOwner,
        SwapAndDepositData calldata swapAndDepositData,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external;

    /**
     * @notice Swaps an EIP-3009 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken does not implement `receiveWithAuthorization` to the specifications of EIP-3009, this call will revert.
     * @dev The nonce for the receiveWithAuthorization signature should match the nonce in the SwapAndDepositData.
     * This nonce is managed by the ERC-3009 token contract.
     * @param signatureOwner The owner of the EIP3009 signature and swapAndDepositData signature. Assumed to be the depositor for the Across spoke pool.
     * @param swapAndDepositData Specifies the params we need to perform a swap on a generic exchange.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param receiveWithAuthSignature EIP3009 signature encoded as (bytes32 r, bytes32 s, uint8 v).
     * @param swapAndDepositDataSignature The signature against the input swapAndDepositData encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function swapAndBridgeWithAuthorization(
        address signatureOwner,
        SwapAndDepositData calldata swapAndDepositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata receiveWithAuthSignature,
        bytes calldata swapAndDepositDataSignature
    ) external;

    /**
     * @notice Deposits an EIP-2612 token Across input token into the Spoke Pool contract.
     * @dev If the token does not implement `permit` to the specifications of EIP-2612, the permit call result will be ignored and the function will continue.
     * @dev If `acrossInputToken` does not implement `permit` to the specifications of EIP-2612, this function will fail.
     * @dev The nonce for the depositData signature must be retrieved from permitNonces(signatureOwner).
     * @dev Design Decision: We use separate nonce tracking for permit-based functions versus
     * receiveWithAuthorization-based functions, which creates a theoretical replay attack that we think is
     * incredibly unlikely because this would require:
     * 1. A token implementing both ERC-2612 and ERC-3009
     * 2. A user using the same nonces for depositWithPermit and for depositWithAuthorization
     * 3. Issuing these signatures within a short amount of time (limited by fillDeadlineBuffer)
     * @param signatureOwner The owner of the permit signature and depositData signature. Assumed to be the depositor for the Across spoke pool.
     * @param depositData Specifies the Across deposit params to send.
     * @param deadline Deadline before which the permit signature is valid.
     * @param permitSignature Permit signature encoded as (bytes32 r, bytes32 s, uint8 v).
     * @param depositDataSignature The signature against the input depositData encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function depositWithPermit(
        address signatureOwner,
        DepositData calldata depositData,
        uint256 deadline,
        bytes calldata permitSignature,
        bytes calldata depositDataSignature
    ) external;

    /**
     * @notice Uses permit2 to transfer and submit an Across deposit to the Spoke Pool contract.
     * @dev This function assumes the caller has properly set an allowance for the permit2 contract on this network.
     * @dev This function assumes that the amount of token to be swapped is equal to the amount of the token to be received from permit2.
     * @param signatureOwner The owner of the permit2 signature and depositor for the Across spoke pool.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     * @param permit The permit data signed over by the owner.
     * @param signature The permit2 signature to verify against the deposit data.
     */
    function depositWithPermit2(
        address signatureOwner,
        DepositData calldata depositData,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external;

    /**
     * @notice Deposits an EIP-3009 compliant Across input token into the Spoke Pool contract.
     * @dev If `acrossInputToken` does not implement `receiveWithAuthorization` to the specifications of EIP-3009, this call will revert.
     * @dev The nonce for the receiveWithAuthorization signature should match the nonce in the DepositData.
     * This nonce is managed by the ERC-3009 token contract.
     * @param signatureOwner The owner of the EIP3009 signature and depositData signature. Assumed to be the depositor for the Across spoke pool.
     * @param depositData Specifies the Across deposit params to send.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param receiveWithAuthSignature EIP3009 signature encoded as (bytes32 r, bytes32 s, uint8 v).
     * @param depositDataSignature The signature against the input depositData encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function depositWithAuthorization(
        address signatureOwner,
        DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata receiveWithAuthSignature,
        bytes calldata depositDataSignature
    ) external;

    /**
     * @notice Returns the current permit nonce for a user.
     * @param user The user whose nonce to return.
     * @return The current permit nonce for the user.
     */
    function permitNonces(address user) external view returns (uint256);
}
