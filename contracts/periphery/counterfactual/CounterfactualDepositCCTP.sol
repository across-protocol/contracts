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
 * @title CounterfactualDepositCCTP
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP, deployed as EIP-1167 clones
 */
abstract contract CounterfactualDepositCCTP is CounterfactualDepositBase {
    using SafeERC20 for IERC20;

    event CCTPDepositExecuted(uint256 amount, address executionFeeRecipient, bytes32 nonce, uint256 cctpDeadline);

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    /**
     * @param _srcPeriphery SponsoredCCTPSrcPeriphery contract address.
     * @param _sourceDomain CCTP source domain ID for this chain.
     */
    constructor(address _srcPeriphery, uint32 _sourceDomain) {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
    }

    function _executeCCTPDeposit(
        CCTPDepositParams memory params,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        bytes calldata signature,
        uint256 executionFee
    ) internal virtual {
        address inputToken = address(uint160(uint256(params.burnToken)));

        if (executionFee > 0) {
            IERC20(inputToken).safeTransfer(executionFeeRecipient, executionFee);
        }

        uint256 depositAmount = amount - executionFee;

        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: params.destinationDomain,
                mintRecipient: params.mintRecipient,
                amount: depositAmount,
                burnToken: params.burnToken,
                destinationCaller: params.destinationCaller,
                maxFee: (depositAmount * params.cctpMaxFeeBps) / BPS_SCALAR,
                minFinalityThreshold: params.minFinalityThreshold,
                nonce: nonce,
                deadline: cctpDeadline,
                maxBpsToSponsor: params.maxBpsToSponsor,
                maxUserSlippageBps: params.maxUserSlippageBps,
                finalRecipient: params.finalRecipient,
                finalToken: params.finalToken,
                destinationDex: params.destinationDex,
                accountCreationMode: params.accountCreationMode,
                executionMode: params.executionMode,
                actionData: params.actionData
            }),
            signature
        );

        emit CCTPDepositExecuted(amount, executionFeeRecipient, nonce, cctpDeadline);
    }
}
