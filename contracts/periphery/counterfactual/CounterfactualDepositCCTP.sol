// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";

/**
 * @notice Minimal interface for calling depositForBurn on SponsoredCCTPSrcPeriphery
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

/**
 * @notice Route parameters committed to in the merkle leaf.
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
    uint256 executionFee;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct CCTPSubmitterData {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 cctpDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositCCTP
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositCCTP is ICounterfactualImplementation {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after a CCTP deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFeeRecipient Address that received the execution fee.
     * @param nonce CCTP nonce used for the deposit.
     * @param cctpDeadline Deadline timestamp for the CCTP quote.
     */
    event CCTPDepositExecuted(
        uint256 amount,
        address indexed executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline
    );

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    constructor(address _srcPeriphery, uint32 _sourceDomain) {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredCCTP. `params` is ABI-encoded as `CCTPDepositParams`;
     *      `submitterData` as `CCTPSubmitterData` (includes a signature forwarded to the CCTP periphery).
     *      ERC-20 only (no native tokens). No local signature verification — delegated to `srcPeriphery`.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        CCTPDepositParams memory dp = abi.decode(params, (CCTPDepositParams));
        CCTPSubmitterData memory sd = abi.decode(submitterData, (CCTPSubmitterData));

        address inputToken = address(uint160(uint256(dp.burnToken)));

        if (dp.executionFee > 0) IERC20(inputToken).safeTransfer(sd.executionFeeRecipient, dp.executionFee);

        uint256 depositAmount = sd.amount - dp.executionFee;

        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        _depositForBurn(dp, sd, depositAmount);

        emit CCTPDepositExecuted(sd.amount, sd.executionFeeRecipient, sd.nonce, sd.cctpDeadline);
    }

    /**
     * @notice Calls depositForBurn on the SponsoredCCTPSrcPeriphery with the constructed quote.
     * @param dp Route parameters from the merkle leaf.
     * @param sd Submitter-provided execution data.
     * @param depositAmount Amount to deposit after deducting the execution fee.
     */
    function _depositForBurn(CCTPDepositParams memory dp, CCTPSubmitterData memory sd, uint256 depositAmount) private {
        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: dp.destinationDomain,
                mintRecipient: dp.mintRecipient,
                amount: depositAmount,
                burnToken: dp.burnToken,
                destinationCaller: dp.destinationCaller,
                maxFee: (depositAmount * dp.cctpMaxFeeBps) / BPS_SCALAR,
                minFinalityThreshold: dp.minFinalityThreshold,
                nonce: sd.nonce,
                deadline: sd.cctpDeadline,
                maxBpsToSponsor: dp.maxBpsToSponsor,
                maxUserSlippageBps: dp.maxUserSlippageBps,
                finalRecipient: dp.finalRecipient,
                finalToken: dp.finalToken,
                destinationDex: dp.destinationDex,
                accountCreationMode: dp.accountCreationMode,
                executionMode: dp.executionMode,
                actionData: dp.actionData
            }),
            sd.signature
        );
    }
}
