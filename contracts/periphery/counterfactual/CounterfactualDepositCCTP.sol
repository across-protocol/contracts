// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";

/**
 * @notice Minimal interface for calling depositForBurn on SponsoredCCTPSrcPeriphery
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
 */
contract CounterfactualDepositCCTP is ICounterfactualImplementation {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_SCALAR = 10_000;

    event CCTPDepositExecuted(uint256 amount, address executionFeeRecipient, bytes32 nonce, uint256 cctpDeadline);

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    constructor(address _srcPeriphery, uint32 _sourceDomain) {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
    }

    /// @inheritdoc ICounterfactualImplementation
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

    function _depositForBurn(CCTPDepositParams memory dp, CCTPSubmitterData memory sd, uint256 depositAmount) internal {
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
