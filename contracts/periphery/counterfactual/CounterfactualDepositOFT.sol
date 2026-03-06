// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Route parameters committed to in the merkle leaf.
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
    uint256 executionFee;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct OFTSubmitterData {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 oftDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositOFT
 * @notice Implementation contract for counterfactual deposits via SponsoredOFT.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher.
 *      msg.value covers LayerZero native messaging fees.
 */
contract CounterfactualDepositOFT is ICounterfactualImplementation {
    using SafeERC20 for IERC20;

    event OFTDepositExecuted(uint256 amount, address executionFeeRecipient, bytes32 nonce, uint256 oftDeadline);

    /// @notice SponsoredOFTSrcPeriphery contract
    address public immutable oftSrcPeriphery;

    /// @notice OFT source endpoint ID for this chain
    uint32 public immutable srcEid;

    constructor(address _oftSrcPeriphery, uint32 _srcEid) {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredOFT (LayerZero). `params` is ABI-encoded as `OFTDepositParams`;
     *      `submitterData` as `OFTSubmitterData` (includes a signature forwarded to the OFT periphery).
     *      ERC-20 only. Forwards `msg.value` for LayerZero messaging fees. No local signature verification.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        OFTDepositParams memory dp = abi.decode(params, (OFTDepositParams));
        OFTSubmitterData memory sd = abi.decode(submitterData, (OFTSubmitterData));

        if (dp.executionFee > 0) IERC20(dp.token).safeTransfer(sd.executionFeeRecipient, dp.executionFee);

        uint256 depositAmount = sd.amount - dp.executionFee;

        IERC20(dp.token).forceApprove(oftSrcPeriphery, depositAmount);

        _deposit(dp, sd, depositAmount);

        emit OFTDepositExecuted(sd.amount, sd.executionFeeRecipient, sd.nonce, sd.oftDeadline);
    }

    function _deposit(OFTDepositParams memory dp, OFTSubmitterData memory sd, uint256 depositAmount) internal {
        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(
            SponsoredOFTInterface.Quote({
                signedParams: SponsoredOFTInterface.SignedQuoteParams({
                    srcEid: srcEid,
                    dstEid: dp.dstEid,
                    destinationHandler: dp.destinationHandler,
                    amountLD: depositAmount,
                    nonce: sd.nonce,
                    deadline: sd.oftDeadline,
                    maxBpsToSponsor: dp.maxBpsToSponsor,
                    maxUserSlippageBps: dp.maxUserSlippageBps,
                    finalRecipient: dp.finalRecipient,
                    finalToken: dp.finalToken,
                    destinationDex: dp.destinationDex,
                    lzReceiveGasLimit: dp.lzReceiveGasLimit,
                    lzComposeGasLimit: dp.lzComposeGasLimit,
                    maxOftFeeBps: dp.maxOftFeeBps,
                    accountCreationMode: dp.accountCreationMode,
                    executionMode: dp.executionMode,
                    actionData: dp.actionData
                }),
                unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({ refundRecipient: dp.refundRecipient })
            }),
            sd.signature
        );
    }
}
