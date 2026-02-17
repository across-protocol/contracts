// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Quote, SignedQuoteParams, UnsignedQuoteParams } from "../mintburn/sponsored-oft/Structs.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Route parameters for OFT deposits
 */
struct OFTImmutables {
    uint32 dstEid;
    bytes32 destinationHandler;
    bytes32 token;
    uint256 maxOftFeeBps;
    uint256 executionFee;
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
    address userWithdrawAddress;
    address adminWithdrawAddress;
    bytes actionData;
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

    /// @notice SponsoredOFTSrcPeriphery contract
    address public immutable oftSrcPeriphery;

    /// @notice OFT source endpoint ID for this chain
    uint32 public immutable srcEid;

    constructor(address _oftSrcPeriphery, uint32 _srcEid) {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
    }

    /**
     * @notice Executes a deposit via SponsoredOFT
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
    ) external payable {
        _verifyParams(params);

        address inputToken = address(uint160(uint256(params.token)));

        // transfer execution fee to execution fee recipient
        if (params.executionFee > 0) {
            IERC20(inputToken).safeTransfer(executionFeeRecipient, params.executionFee);
        }

        uint256 depositAmount = amount - params.executionFee;

        IERC20(inputToken).forceApprove(oftSrcPeriphery, depositAmount);

        Quote memory quote = Quote({
            signedParams: SignedQuoteParams({
                srcEid: srcEid,
                dstEid: params.dstEid,
                destinationHandler: params.destinationHandler,
                amountLD: depositAmount,
                nonce: nonce,
                deadline: oftDeadline,
                maxBpsToSponsor: params.maxBpsToSponsor,
                maxUserSlippageBps: params.maxUserSlippageBps,
                finalRecipient: params.finalRecipient,
                finalToken: params.finalToken,
                destinationDex: params.destinationDex,
                lzReceiveGasLimit: params.lzReceiveGasLimit,
                lzComposeGasLimit: params.lzComposeGasLimit,
                maxOftFeeBps: params.maxOftFeeBps,
                accountCreationMode: params.accountCreationMode,
                executionMode: params.executionMode,
                actionData: params.actionData
            }),
            unsignedParams: UnsignedQuoteParams({ refundRecipient: params.refundRecipient })
        });

        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(quote, signature);

        emit DepositExecuted(address(this), depositAmount, nonce);
    }

    /**
     * @notice Allows admin to withdraw any token from this clone.
     * @param params Route parameters (verified against stored hash).
     * @param token ERC20 token to withdraw.
     * @param to Recipient of the withdrawn tokens.
     * @param amount Amount to withdraw.
     */
    function adminWithdraw(OFTImmutables memory params, address token, address to, uint256 amount) external {
        _verifyParams(params);
        _adminWithdraw(params.adminWithdrawAddress, token, to, amount);
    }

    /**
     * @notice Allows user to withdraw tokens before execution.
     * @param params Route parameters (verified against stored hash).
     * @param token ERC20 token to withdraw.
     * @param to Recipient of the withdrawn tokens.
     * @param amount Amount to withdraw.
     */
    function userWithdraw(OFTImmutables memory params, address token, address to, uint256 amount) external {
        _verifyParams(params);
        _userWithdraw(params.userWithdrawAddress, token, to, amount);
    }

    /// @dev Hashes caller-supplied params and checks against the clone's stored hash.
    /// @param params Route parameters to verify.
    function _verifyParams(OFTImmutables memory params) internal view {
        _verifyParamsHash(keccak256(abi.encode(params)));
    }
}
