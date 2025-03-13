//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20Auth } from "../external/interfaces/IERC20Auth.sol";
import { SpokePoolV3Periphery } from "../SpokePoolV3Periphery.sol";
import { PeripherySigningLib } from "../libraries/PeripherySigningLib.sol";
import { IPermit2 } from "../external/interfaces/IPermit2.sol";

interface SpokePoolV3PeripheryProxyInterface {
    /**
     * @notice Swaps tokens on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param swapAndDepositData Specifies the params we need to perform a swap on a generic exchange.
     */
    function swapAndBridge(SpokePoolV3PeripheryInterface.SwapAndDepositData calldata swapAndDepositData) external;
}

/**
 * @title SpokePoolV3Periphery
 * @notice Contract for performing more complex interactions with an Across spoke pool deployment.
 * @dev Variables which may be immutable are not marked as immutable, nor defined in the constructor, so that this
 * contract may be deployed deterministically at the same address across different networks.
 * @custom:security-contact bugs@across.to
 */
interface SpokePoolV3PeripheryInterface {
    // Enum describing the method of transferring tokens to an exchange.
    enum TransferType {
        // Approve the exchange so that it may transfer tokens from this contract.
        Approval,
        // Transfer tokens to the exchange before calling it in this contract.
        Transfer,
        // Approve the exchange by authorizing a transfer with Permit2.
        Permit2Approval
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
        uint256 destinationChainId;
        // The account that can exclusively fill the deposit before the exclusivity parameter.
        address exclusiveRelayer;
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
    }

    // Extended deposit data to be used specifically for signing off on periphery deposits.
    struct DepositData {
        // Amount of fees to pay for submitting transaction. Unused in gasful flows.
        Fees submissionFees;
        // Deposit data describing the parameters for the V3 Across deposit.
        BaseDepositData baseDepositData;
        // The precise input amount to deposit into the spoke pool.
        uint256 inputAmount;
    }

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
     * @param swapAndDepositData Specifies the data needed to perform a swap on a generic exchange.
     */
    function swapAndBridge(SwapAndDepositData calldata swapAndDepositData) external payable;

    /**
     * @notice Swaps an EIP-2612 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If the swapToken in swapData does not implement `permit` to the specifications of EIP-2612, this function will fail.
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
     * @param signatureOwner The owner of the EIP3009 signature and swapAndDepositData signature. Assumed to be the depositor for the Across spoke pool.
     * @param swapAndDepositData Specifies the params we need to perform a swap on a generic exchange.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param nonce Unique nonce used in the `receiveWithAuthorization` signature.
     * @param receiveWithAuthSignature EIP3009 signature encoded as (bytes32 r, bytes32 s, uint8 v).
     * @param swapAndDepositDataSignature The signature against the input swapAndDepositData encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function swapAndBridgeWithAuthorization(
        address signatureOwner,
        SwapAndDepositData calldata swapAndDepositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata receiveWithAuthSignature,
        bytes calldata swapAndDepositDataSignature
    ) external;

    /**
     * @notice Deposits an EIP-2612 token Across input token into the Spoke Pool contract.
     * @dev If `acrossInputToken` does not implement `permit` to the specifications of EIP-2612, this function will fail.
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
     * @param signatureOwner The owner of the EIP3009 signature and depositData signature. Assumed to be the depositor for the Across spoke pool.
     * @param depositData Specifies the Across deposit params to send.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param nonce Unique nonce used in the `receiveWithAuthorization` signature.
     * @param receiveWithAuthSignature EIP3009 signature encoded as (bytes32 r, bytes32 s, uint8 v).
     * @param depositDataSignature The signature against the input depositData encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function depositWithAuthorization(
        address signatureOwner,
        DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata receiveWithAuthSignature,
        bytes calldata depositDataSignature
    ) external;
}
