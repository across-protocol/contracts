// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Parameters passed through to SponsoredOFTSrcPeriphery.deposit()
 */
struct OFTDepositParams {
    uint32 dstEid;
    bytes32 destinationHandler;
    address token;
    uint256 maxOftFeeBps;
    uint256 lzReceiveGasLimit;
    uint256 lzComposeGasLimit;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    bytes32 finalRecipient;
    bytes32 finalToken;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    address refundRecipient;
    bytes actionData;
}

/**
 * @notice Parameters used by the clone's execution logic
 */
struct OFTExecutionParams {
    uint256 executionFee;
    address userWithdrawAddress;
    address adminWithdrawAddress;
}

/**
 * @notice Combined route parameters for OFT deposits
 */
struct OFTImmutables {
    OFTDepositParams depositParams;
    OFTExecutionParams executionParams;
}

/**
 * @title CounterfactualDepositOFT
 * @notice Implementation contract for counterfactual deposits via SponsoredOFT, deployed as EIP-1167 clones
 * @dev The factory deploys minimal proxies (clones) of this contract. On execution, the clone builds a
 *      Quote from its immutable route params + caller-supplied execution params and forwards it to
 *      SponsoredOFTSrcPeriphery. msg.value covers LayerZero native messaging fees.
 */
contract CounterfactualDepositOFT is CounterfactualDepositBase {
    using SafeERC20 for IERC20;

    event OFTDepositExecuted(uint256 amount, address executionFeeRecipient, bytes32 nonce, uint256 oftDeadline);

    /// @notice SponsoredOFTSrcPeriphery contract
    address public immutable oftSrcPeriphery;

    /// @notice OFT source endpoint ID for this chain
    uint32 public immutable srcEid;

    /**
     * @param _oftSrcPeriphery SponsoredOFTSrcPeriphery contract address.
     * @param _srcEid OFT source endpoint ID for this chain.
     */
    constructor(address _oftSrcPeriphery, uint32 _srcEid) {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
    }

    /**
     * @notice Executes a deposit via SponsoredOFT
     * @dev The caller must supply msg.value to cover the LayerZero native messaging fee.
     *      This fee is paid by the caller, not from the user's deposited tokens—so the
     *      executor's incentive (executionFee) must cover both the origin tx gas cost
     *      and the LayerZero fee.
     * @param params Route parameters (verified against stored hash)
     * @param amount Gross amount of token (includes executionFee)
     * @param executionFeeRecipient Address that receives the execution fee
     * @param nonce Unique nonce for SponsoredOFT replay protection
     * @param oftDeadline Deadline for the SponsoredOFT quote (validated by SrcPeriphery)
     * @param signature Signature from SponsoredOFT quote signer
     */
    function executeDeposit(
        OFTImmutables memory params,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes calldata signature
    ) external payable verifyParamsHash(keccak256(abi.encode(params))) {
        // transfer execution fee to execution fee recipient
        if (params.executionParams.executionFee > 0) {
            IERC20(params.depositParams.token).safeTransfer(executionFeeRecipient, params.executionParams.executionFee);
        }

        uint256 depositAmount = amount - params.executionParams.executionFee;

        IERC20(params.depositParams.token).forceApprove(oftSrcPeriphery, depositAmount);

        SponsoredOFTInterface.Quote memory quote = SponsoredOFTInterface.Quote({
            signedParams: SponsoredOFTInterface.SignedQuoteParams({
                srcEid: srcEid,
                dstEid: params.depositParams.dstEid,
                destinationHandler: params.depositParams.destinationHandler,
                amountLD: depositAmount,
                nonce: nonce,
                deadline: oftDeadline,
                maxBpsToSponsor: params.depositParams.maxBpsToSponsor,
                maxUserSlippageBps: params.depositParams.maxUserSlippageBps,
                finalRecipient: params.depositParams.finalRecipient,
                finalToken: params.depositParams.finalToken,
                destinationDex: params.depositParams.destinationDex,
                lzReceiveGasLimit: params.depositParams.lzReceiveGasLimit,
                lzComposeGasLimit: params.depositParams.lzComposeGasLimit,
                maxOftFeeBps: params.depositParams.maxOftFeeBps,
                accountCreationMode: params.depositParams.accountCreationMode,
                executionMode: params.depositParams.executionMode,
                actionData: params.depositParams.actionData
            }),
            unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({
                refundRecipient: params.depositParams.refundRecipient
            })
        });

        // Forward caller-supplied msg.value to cover LayerZero native messaging fee.
        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(quote, signature);

        emit OFTDepositExecuted(amount, executionFeeRecipient, nonce, oftDeadline);
    }

    /// @inheritdoc CounterfactualDepositBase
    function _getUserWithdrawAddress(bytes calldata params) internal pure override returns (address) {
        return abi.decode(params, (OFTImmutables)).executionParams.userWithdrawAddress;
    }

    /// @inheritdoc CounterfactualDepositBase
    function _getAdminWithdrawAddress(bytes calldata params) internal pure override returns (address) {
        return abi.decode(params, (OFTImmutables)).executionParams.adminWithdrawAddress;
    }
}
