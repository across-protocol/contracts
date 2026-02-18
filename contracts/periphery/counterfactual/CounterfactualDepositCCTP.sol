// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

/**
 * @notice Minimal interface for calling depositForBurn on SponsoredCCTPSrcPeriphery
 */
interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

/**
 * @notice Parameters passed through to SponsoredCCTPSrcPeriphery.depositForBurn()
 */
struct CCTPDepositParams {
    uint32 destinationDomain;
    bytes32 mintRecipient;
    bytes32 burnToken;
    bytes32 destinationCaller;
    uint256 cctpMaxFeeBps;
    uint32 minFinalityThreshold;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    bytes32 finalRecipient;
    bytes32 finalToken;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    bytes actionData;
}

/**
 * @notice Parameters used by the clone's execution logic
 */
struct CCTPExecutionParams {
    uint256 executionFee;
    address userWithdrawAddress;
    address adminWithdrawAddress;
}

/**
 * @notice Combined route parameters for CCTP deposits
 */
struct CCTPImmutables {
    CCTPDepositParams depositParams;
    CCTPExecutionParams executionParams;
}

/**
 * @title CounterfactualDepositCCTP
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP, deployed as EIP-1167 clones
 * @dev The factory deploys minimal proxies (clones) of this contract using OZ Clones.cloneDeterministicWithImmutableArgs.
 *      Route parameters are appended to the clone bytecode and read via Clones.fetchCloneArgs.
 *      On execution, the clone builds a SponsoredCCTPQuote from its immutable route params + caller-supplied
 *      execution params (amount, nonce, cctpDeadline, executeDepositDeadline) and forwards it to SponsoredCCTPSrcPeriphery.
 */
contract CounterfactualDepositCCTP is CounterfactualDepositBase {
    using SafeERC20 for IERC20;

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    /// @dev Hashes caller-supplied params and checks against the clone's stored hash.
    modifier verifyParams(CCTPImmutables memory params) {
        _verifyParamsHash(keccak256(abi.encode(params)));
        _;
    }

    constructor(address _srcPeriphery, uint32 _sourceDomain) {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
    }

    /**
     * @notice Executes a deposit via SponsoredCCTP
     * @param params Route parameters (verified against stored hash)
     * @param amount Gross amount of burnToken (includes executionFee)
     * @param executionFeeRecipient Address that receives the execution fee
     * @param nonce Unique nonce for SponsoredCCTP replay protection
     * @param cctpDeadline Deadline for the SponsoredCCTP quote (validated by SrcPeriphery)
     * @param signature Signature from SponsoredCCTP quote signer
     */
    function executeDeposit(
        CCTPImmutables memory params,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        bytes calldata signature
    ) external verifyParams(params) {
        address inputToken = address(uint160(uint256(params.depositParams.burnToken)));

        // transfer execution fee to execution fee recipient
        if (params.executionParams.executionFee > 0) {
            IERC20(inputToken).safeTransfer(executionFeeRecipient, params.executionParams.executionFee);
        }

        uint256 depositAmount = amount - params.executionParams.executionFee;

        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: params.depositParams.destinationDomain,
                mintRecipient: params.depositParams.mintRecipient,
                amount: depositAmount,
                burnToken: params.depositParams.burnToken,
                destinationCaller: params.depositParams.destinationCaller,
                maxFee: (depositAmount * params.depositParams.cctpMaxFeeBps) / BPS_SCALAR,
                minFinalityThreshold: params.depositParams.minFinalityThreshold,
                nonce: nonce,
                deadline: cctpDeadline,
                maxBpsToSponsor: params.depositParams.maxBpsToSponsor,
                maxUserSlippageBps: params.depositParams.maxUserSlippageBps,
                finalRecipient: params.depositParams.finalRecipient,
                finalToken: params.depositParams.finalToken,
                destinationDex: params.depositParams.destinationDex,
                accountCreationMode: params.depositParams.accountCreationMode,
                executionMode: params.depositParams.executionMode,
                actionData: params.depositParams.actionData
            }),
            signature
        );

        emit CounterfactualDepositExecuted(
            depositAmount,
            nonce,
            executionFeeRecipient,
            params.executionParams.executionFee
        );
    }

    /**
     * @notice Allows admin to withdraw any token from this clone.
     * @param params Route parameters (verified against stored hash).
     * @param token ERC20 token to withdraw.
     * @param to Recipient of the withdrawn tokens.
     * @param amount Amount to withdraw.
     */
    function adminWithdraw(
        CCTPImmutables memory params,
        address token,
        address to,
        uint256 amount
    ) external verifyParams(params) {
        _adminWithdraw(params.executionParams.adminWithdrawAddress, token, to, amount);
    }

    /**
     * @notice Allows user to withdraw tokens before execution.
     * @param params Route parameters (verified against stored hash).
     * @param token ERC20 token to withdraw.
     * @param to Recipient of the withdrawn tokens.
     * @param amount Amount to withdraw.
     */
    function userWithdraw(
        CCTPImmutables memory params,
        address token,
        address to,
        uint256 amount
    ) external verifyParams(params) {
        _userWithdraw(params.executionParams.userWithdrawAddress, token, to, amount);
    }
}
