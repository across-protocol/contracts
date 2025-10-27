// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { HyperCoreLib } from "./HyperCoreLib.sol";
import { CoreTokenInfo, FinalTokenInfo } from "../periphery/mintburn/Structs.sol";

contract HyperCoreFlowLib {
    address public constant HYPER_CORE_LIB_ADDRESS = 0x362850664E624639777999840971B19e01763175;

    struct SponsorshipAmount {
        uint64 minAllowableAmountToForwardCore;
        uint64 maxAllowableAmountToForwardCore;
    }

    struct SimpleTransferFlowResult {
        bool fb;
        uint256 amt;
        uint256 evmAmt;
        uint64 coreAmt;
        bool safe;
    }

    struct SwapFlowResult {
        bool fb;
        bool revertSimple;
        bool revertFb;
        uint64 minAmt;
        uint64 maxAmt;
        uint256 evm;
        uint64 core;
        uint256 slippage;
    }

    function calcAllowableAmtsSwapFlow(
        uint256 amount,
        uint256 extraFeesIncurred,
        CoreTokenInfo memory initialCoreTokenInfo,
        CoreTokenInfo memory finalCoreTokenInfo,
        bool isSponsoredFlow,
        uint256 maxUserSlippageBps
    ) internal pure returns (SponsorshipAmount memory sponsorshipAmount) {
        (, uint64 feelessAmountCoreInitialToken) = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).maximumEVMSendAmountToAmounts(
            amount + extraFeesIncurred,
            initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
        uint64 feelessAmountCoreFinalToken = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).convertCoreDecimalsSimple(
            feelessAmountCoreInitialToken,
            initialCoreTokenInfo.tokenInfo.weiDecimals,
            finalCoreTokenInfo.tokenInfo.weiDecimals
        );
        if (isSponsoredFlow) {
            sponsorshipAmount.minAllowableAmountToForwardCore = feelessAmountCoreFinalToken;
            sponsorshipAmount.maxAllowableAmountToForwardCore = feelessAmountCoreFinalToken;
        } else {
            sponsorshipAmount.minAllowableAmountToForwardCore = uint64(
                (feelessAmountCoreFinalToken * (10000 - maxUserSlippageBps)) / 10000
            );
            sponsorshipAmount.maxAllowableAmountToForwardCore = uint64(
                (feelessAmountCoreFinalToken * amount) / (amount + extraFeesIncurred)
            );
        }
    }

    function calcSwapFlowSendAmounts(
        uint64 limitOrderOut,
        uint64 minAmountToSend,
        uint64 maxAmountToSend,
        bool isSponsored
    ) external pure returns (uint64 totalToSend, uint64 additionalToSend) {
        if (limitOrderOut >= maxAmountToSend || isSponsored) {
            totalToSend = maxAmountToSend;
        } else {
            if (limitOrderOut < minAmountToSend) {
                additionalToSend = minAmountToSend - limitOrderOut;
            }
            totalToSend = limitOrderOut + additionalToSend;
        }
    }

    function getApproxRealizedPrice(
        FinalTokenInfo memory finalTokenInfo
    ) internal view returns (uint64 limitPriceX1e8) {
        uint64 spotX1e8 = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).spotPx(finalTokenInfo.assetIndex);
        uint256 adjPpm = finalTokenInfo.isBuy
            ? (1000000 + finalTokenInfo.suggestedDiscountBps * 100 + finalTokenInfo.feePpm)
            : (1000000 - finalTokenInfo.suggestedDiscountBps * 100 - finalTokenInfo.feePpm);
        limitPriceX1e8 = uint64((uint256(spotX1e8) * adjPpm) / 1000000);
    }

    /**
     * @notice Calculates estimated slippage in PPM for a swap flow
     * @param approxExecutionPriceX1e8 The approximate execution price
     * @param isBuy Whether this is a buy or sell
     * @param extraFeesIncurred Extra fees incurred
     * @param amountInEVM The amount in EVM
     * @return estSlippagePpm The estimated slippage in parts per million
     */
    function calcEstimatedSlippagePpm(
        uint64 approxExecutionPriceX1e8,
        bool isBuy,
        uint256 extraFeesIncurred,
        uint256 amountInEVM
    ) internal pure returns (uint256 estSlippagePpm) {
        if (isBuy) {
            if (approxExecutionPriceX1e8 < 100000000) {
                estSlippagePpm = 0;
            } else {
                // ceil
                estSlippagePpm = ((approxExecutionPriceX1e8 - 100000000) * 1000000 + 99999999) / 100000000;
            }
        } else {
            if (approxExecutionPriceX1e8 > 100000000) {
                estSlippagePpm = 0;
            } else {
                // ceil
                estSlippagePpm = ((100000000 - approxExecutionPriceX1e8) * 1000000 + 99999999) / 100000000;
            }
        }
        // Add `extraFeesIncurred` to "slippage from one to one"
        estSlippagePpm +=
            (extraFeesIncurred * 1000000 + (amountInEVM + extraFeesIncurred) - 1) /
            (amountInEVM + extraFeesIncurred);
    }

    /**
     * @notice Calculates sponsorship amount for simple transfer flow
     * @param amountInEVM The amount in EVM
     * @param extraFeesIncurred Extra fees incurred
     * @param maxBpsToSponsor Maximum basis points to sponsor
     * @return amountToSponsor The amount to sponsor
     */
    function calcSponsorshipAmount(
        uint256 amountInEVM,
        uint256 extraFeesIncurred,
        uint256 maxBpsToSponsor
    ) internal pure returns (uint256 amountToSponsor) {
        uint256 maxEvmAmountToSponsor = ((amountInEVM + extraFeesIncurred) * maxBpsToSponsor) / 10000;
        amountToSponsor = extraFeesIncurred;
        if (amountToSponsor > maxEvmAmountToSponsor) {
            amountToSponsor = maxEvmAmountToSponsor;
        }
    }

    /**
     * @notice Validates and calculates transfer amounts for simple transfer flow
     * @param finalAmount The final amount to transfer
     * @param evmExtraWeiDecimals EVM extra wei decimals
     * @param coreIndex Core index for the token
     * @param bridgeSafetyBufferCore Bridge safety buffer on core
     * @return quotedEvmAmount The quoted EVM amount
     * @return quotedCoreAmount The quoted core amount
     * @return isSafe Whether the transfer is safe
     */
    function validateAndCalcTransferAmounts(
        uint256 finalAmount,
        uint8 evmExtraWeiDecimals,
        uint32 coreIndex,
        uint64 bridgeSafetyBufferCore
    ) internal view returns (uint256 quotedEvmAmount, uint64 quotedCoreAmount, bool isSafe) {
        (quotedEvmAmount, quotedCoreAmount) = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).maximumEVMSendAmountToAmounts(
            finalAmount,
            int8(evmExtraWeiDecimals)
        );
        isSafe = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).isCoreAmountSafeToBridge(
            coreIndex,
            quotedCoreAmount,
            bridgeSafetyBufferCore
        );
    }

    /**
     * @notice Calculates fallback sponsorship amount for HyperEVM flow
     * @param amountInEVM Amount in EVM
     * @param extraFeesIncurred Extra fees incurred
     * @param maxBpsToSponsor Maximum basis points to sponsor
     * @return sponsorshipFundsToForward Amount of sponsorship funds to forward
     */
    function calcFallbackSponsorshipAmount(
        uint256 amountInEVM,
        uint256 extraFeesIncurred,
        uint256 maxBpsToSponsor
    ) external pure returns (uint256 sponsorshipFundsToForward) {
        uint256 maxEvmAmountToSponsor = ((amountInEVM + extraFeesIncurred) * maxBpsToSponsor) / 10000;
        sponsorshipFundsToForward = extraFeesIncurred > maxEvmAmountToSponsor
            ? maxEvmAmountToSponsor
            : extraFeesIncurred;
    }

    /**
     * @notice Builds and validates CoreTokenInfo for a token
     * @param token The token address
     * @param coreIndex The core index
     * @param accountActivationFeeCore Account activation fee in core units
     * @return tokenInfo The token info from HyperCoreLib
     * @return accountActivationFeeEVM Account activation fee in EVM units
     */
    function buildCoreTokenInfo(
        address token,
        uint32 coreIndex,
        uint64 accountActivationFeeCore
    ) external view returns (HyperCoreLib.TokenInfo memory tokenInfo, uint256 accountActivationFeeEVM) {
        tokenInfo = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).tokenInfo(coreIndex);
        require(tokenInfo.evmContract == token, "Token mismatch");

        (accountActivationFeeEVM, ) = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).minimumCoreReceiveAmountToAmounts(
            accountActivationFeeCore,
            tokenInfo.evmExtraWeiDecimals
        );
    }

    /**
     * @notice Validates bridge safety for finalizing swap flows
     * @param totalAdditionalToSend Total additional amount to send
     * @param evmExtraWeiDecimals EVM extra wei decimals
     * @param coreIndex Core token index
     * @param bridgeSafetyBufferCore Bridge safety buffer
     * @return totalAdditionalToSendEVM Amount to send in EVM units
     * @return totalAdditionalReceivedCore Amount to receive in core units
     * @return isSafe Whether the bridge is safe
     */
    function validateFinalizeSafety(
        uint64 totalAdditionalToSend,
        uint8 evmExtraWeiDecimals,
        uint32 coreIndex,
        uint64 bridgeSafetyBufferCore
    ) external view returns (uint256 totalAdditionalToSendEVM, uint64 totalAdditionalReceivedCore, bool isSafe) {
        (totalAdditionalToSendEVM, totalAdditionalReceivedCore) = HyperCoreLib(HYPER_CORE_LIB_ADDRESS)
            .minimumCoreReceiveAmountToAmounts(totalAdditionalToSend, int8(evmExtraWeiDecimals));

        isSafe = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).isCoreAmountSafeToBridge(
            coreIndex,
            totalAdditionalReceivedCore,
            bridgeSafetyBufferCore
        );
    }

    /**
     * @notice Validates bridge safety for main token in swap flow
     * @param amountInEVM Amount in EVM
     * @param evmExtraWeiDecimals EVM extra wei decimals
     * @param coreIndex Core token index
     * @param bridgeSafetyBufferCore Bridge safety buffer
     * @return tokensToSendEvm Tokens to send in EVM
     * @return coreAmountIn Core amount in
     * @return isSafe Whether bridge is safe
     */
    function validateSwapBridgeSafety(
        uint256 amountInEVM,
        uint8 evmExtraWeiDecimals,
        uint32 coreIndex,
        uint64 bridgeSafetyBufferCore
    ) internal view returns (uint256 tokensToSendEvm, uint64 coreAmountIn, bool isSafe) {
        (tokensToSendEvm, coreAmountIn) = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).maximumEVMSendAmountToAmounts(
            amountInEVM,
            int8(evmExtraWeiDecimals)
        );

        isSafe = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).isCoreAmountSafeToBridge(
            coreIndex,
            coreAmountIn,
            bridgeSafetyBufferCore
        );
    }

    /**
     * @notice Validates if slippage is acceptable for swap flow
     * @param estSlippagePpm Estimated slippage in PPM
     * @param maxBpsToSponsor Max basis points to sponsor
     * @param maxUserSlippageBps Max user slippage in basis points
     * @return isTooExpensive Whether the swap is too expensive
     * @return estBpsSlippage Estimated slippage in basis points
     */
    function validateSwapSlippage(
        uint256 estSlippagePpm,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps
    ) internal pure returns (bool isTooExpensive, uint256 estBpsSlippage) {
        uint256 maxAllowableBpsDeviation = maxBpsToSponsor > 0 ? maxBpsToSponsor : maxUserSlippageBps;
        estBpsSlippage = (estSlippagePpm + 99) / 100;
        isTooExpensive = estSlippagePpm > maxAllowableBpsDeviation * 100;
    }

    /**
     * @notice Validates account activation conditions
     * @param finalRecipient The final recipient address
     * @param canBeUsedForAccountActivation Whether token can be used for activation
     * @param coreIndex Core token index
     * @param accountActivationFeeCore Activation fee in core units
     * @param bridgeSafetyBufferCore Bridge safety buffer
     * @return isValid Whether activation is valid
     */
    function validateAccountActivation(
        address finalRecipient,
        bool canBeUsedForAccountActivation,
        uint32 coreIndex,
        uint64 accountActivationFeeCore,
        uint64 bridgeSafetyBufferCore
    ) external view returns (bool isValid) {
        if (HyperCoreLib(HYPER_CORE_LIB_ADDRESS).coreUserExists(finalRecipient)) return false;
        if (!canBeUsedForAccountActivation) return false;
        return
            HyperCoreLib(HYPER_CORE_LIB_ADDRESS).isCoreAmountSafeToBridge(
                coreIndex,
                accountActivationFeeCore,
                bridgeSafetyBufferCore
            );
    }

    /**
     * @notice Validates sponsorship funds transfer safety
     * @param amount Amount to send
     * @param evmExtraWeiDecimals EVM extra wei decimals
     * @param coreIndex Core token index
     * @param bridgeSafetyBufferCore Bridge safety buffer
     * @return amountEVMToSend Amount to send in EVM units
     * @return amountCoreToReceive Amount to receive in core units
     * @return isSafe Whether transfer is safe
     */
    function validateSponsorshipTransfer(
        uint256 amount,
        uint8 evmExtraWeiDecimals,
        uint32 coreIndex,
        uint64 bridgeSafetyBufferCore
    ) external view returns (uint256 amountEVMToSend, uint64 amountCoreToReceive, bool isSafe) {
        (amountEVMToSend, amountCoreToReceive) = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).maximumEVMSendAmountToAmounts(
            amount,
            int8(evmExtraWeiDecimals)
        );
        isSafe = HyperCoreLib(HYPER_CORE_LIB_ADDRESS).isCoreAmountSafeToBridge(
            coreIndex,
            amountCoreToReceive,
            bridgeSafetyBufferCore
        );
    }

    /**
     * @notice Executes simple transfer flow logic - all calculations and validations
     * @param finalRecipient The final recipient address
     * @param amountInEVM Amount in EVM
     * @param extraFeesIncurred Extra fees incurred
     * @param maxBpsToSponsor Max basis points to sponsor
     * @param evmExtraWeiDecimals EVM extra wei decimals
     * @param coreIndex Core token index
     * @param bridgeSafetyBufferCore Bridge safety buffer
     * @param donationBoxBalance Available balance in donation box
     * @return result The calculated result
     */
    function executeSimpleTransferFlowLogic(
        address finalRecipient,
        uint256 amountInEVM,
        uint256 extraFeesIncurred,
        uint256 maxBpsToSponsor,
        uint8 evmExtraWeiDecimals,
        uint32 coreIndex,
        uint64 bridgeSafetyBufferCore,
        uint256 donationBoxBalance
    ) external view returns (SimpleTransferFlowResult memory result) {
        // Check account activation
        if (!HyperCoreLib(HYPER_CORE_LIB_ADDRESS).coreUserExists(finalRecipient)) {
            result.fb = true;
            return result;
        }

        // Calculate sponsorship amount
        result.amt = calcSponsorshipAmount(amountInEVM, extraFeesIncurred, maxBpsToSponsor);

        // Check donation box availability
        if (result.amt > 0 && donationBoxBalance < result.amt) {
            result.amt = 0;
        }

        // Calculate quoted amounts and check safety
        uint256 finalAmount = amountInEVM + result.amt;
        (result.evmAmt, result.coreAmt, result.safe) = validateAndCalcTransferAmounts(
            finalAmount,
            evmExtraWeiDecimals,
            coreIndex,
            bridgeSafetyBufferCore
        );
    }

    /**
     * @notice Executes swap flow initiation logic - all calculations and validations
     * @param finalRecipient The final recipient address
     * @param amountInEVM Amount in EVM
     * @param extraFeesIncurred Extra fees incurred
     * @param maxBpsToSponsor Max basis points to sponsor
     * @param initialCoreTokenInfo Initial token info
     * @param finalCoreTokenInfo Final token info
     * @param finalTokenInfo Final token market info
     * @param maxUserSlippageBps Max user slippage in bps
     * @return result The calculated result
     */
    function initiateSwapFlowLogic(
        address finalRecipient,
        uint256 amountInEVM,
        uint256 extraFeesIncurred,
        uint256 maxBpsToSponsor,
        CoreTokenInfo memory initialCoreTokenInfo,
        CoreTokenInfo memory finalCoreTokenInfo,
        FinalTokenInfo memory finalTokenInfo,
        uint256 maxUserSlippageBps
    ) external view returns (SwapFlowResult memory result) {
        // Check account activation
        if (!HyperCoreLib(HYPER_CORE_LIB_ADDRESS).coreUserExists(finalRecipient)) {
            result.fb = true;
            return result;
        }

        // Calculate sponsorship amounts
        SponsorshipAmount memory sponsorshipAmount = calcAllowableAmtsSwapFlow(
            amountInEVM,
            extraFeesIncurred,
            initialCoreTokenInfo,
            finalCoreTokenInfo,
            maxBpsToSponsor > 0,
            maxUserSlippageBps
        );

        result.minAmt = sponsorshipAmount.minAllowableAmountToForwardCore;
        result.maxAmt = sponsorshipAmount.maxAllowableAmountToForwardCore;

        // Calculate price and slippage
        uint64 approxExecutionPriceX1e8 = getApproxRealizedPrice(finalTokenInfo);

        uint256 estSlippagePpm = calcEstimatedSlippagePpm(
            approxExecutionPriceX1e8,
            finalTokenInfo.isBuy,
            extraFeesIncurred,
            amountInEVM
        );

        (bool isTooExpensive, uint256 estBpsSlippage) = validateSwapSlippage(
            estSlippagePpm,
            maxBpsToSponsor,
            maxUserSlippageBps
        );

        result.slippage = estBpsSlippage;

        if (isTooExpensive) {
            result.revertSimple = true;
            return result;
        }

        // Validate bridge safety
        bool isSafe;
        (result.evm, result.core, isSafe) = validateSwapBridgeSafety(
            amountInEVM,
            uint8(initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals),
            uint32(initialCoreTokenInfo.coreIndex),
            initialCoreTokenInfo.bridgeSafetyBufferCore
        );

        if (!isSafe) {
            result.revertFb = true;
        }
    }
}
