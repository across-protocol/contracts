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
 * @title CounterfactualDepositOFT
 * @notice Implementation contract for counterfactual deposits via SponsoredOFT, deployed as EIP-1167 clones
 */
abstract contract CounterfactualDepositOFT is CounterfactualDepositBase {
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

    function _executeOFTDeposit(
        OFTDepositParams memory params,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes calldata signature,
        uint256 executionFee
    ) internal virtual {
        if (executionFee > 0) {
            IERC20(params.token).safeTransfer(executionFeeRecipient, executionFee);
        }

        uint256 depositAmount = amount - executionFee;

        IERC20(params.token).forceApprove(oftSrcPeriphery, depositAmount);

        SponsoredOFTInterface.Quote memory quote = SponsoredOFTInterface.Quote({
            signedParams: SponsoredOFTInterface.SignedQuoteParams({
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
            unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({ refundRecipient: params.refundRecipient })
        });

        // Forward caller-supplied msg.value to cover LayerZero native messaging fee.
        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(quote, signature);

        emit OFTDepositExecuted(amount, executionFeeRecipient, nonce, oftDeadline);
    }
}
