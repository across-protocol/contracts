// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

library LimitOrderCalcUtils {
    uint256 constant PPM_SCALAR = 10 ** 6;
    uint256 constant BPS_SCALAR = 10 ** 4;
    uint8 constant PX_D = 8;

    /// @notice Reads the current spot price from HyperLiquid and applies a configured suggested discount for faster execution
    function _getSuggestedPriceX1e8(
        uint64 spotX1e8,
        bool isBuy,
        uint32 suggestedDiscountBps
    ) internal view returns (uint64 limitPriceX1e8) {
        // Buy above spot, sell below spot
        uint256 adjBps = isBuy ? (BPS_SCALAR + suggestedDiscountBps) : (BPS_SCALAR - suggestedDiscountBps);
        limitPriceX1e8 = uint64((uint256(spotX1e8) * adjBps) / BPS_SCALAR);
    }

    /**************************************
     *    LIMIT ORDER CALCULATION UTILS   *
     **************************************/

    /// @notice Given the size and price of a limit order, returns the remaining `budget` that Limit order expects to spend
    function _calcRemainingLOBudget(
        uint64 pxX1e8,
        uint64 szX1e8,
        bool isBuy,
        uint64 feePpm,
        uint8 weiDecimalsTokenHave,
        uint8 weiDecimalsTokenWant
    ) internal pure returns (uint64 budget) {
        uint8 quoteWeiD = isBuy ? weiDecimalsTokenHave : weiDecimalsTokenWant;
        uint8 baseWeiD = isBuy ? weiDecimalsTokenWant : weiDecimalsTokenHave;

        if (isBuy) {
            // We have quoteTokens. Estimate how many quoteTokens we are GUARANTEED to have had to enqueue the LO in the first place (proportional)
            // qTR is quote tokens real. qTD quote token decimals.
            // szX1e8 * pxX1e8 / 10 ** 8 = qTX1e8Net
            // qTR * 10 ** 8 * (10 ** 6 - feePpm) / (10 ** 6 * 10 ** qTD) = qTX1e8Net
            // qTR = szX1e8 * pxX1e8 * 10 ** 6 * 10 ** qTD / (10 ** 8 * 10 ** 8 * (10 ** 6 - feePpm))
            budget = uint64(
                (uint256(szX1e8) * uint256(pxX1e8) * PPM_SCALAR * 10 ** (quoteWeiD)) /
                    (10 ** 16 * (PPM_SCALAR - feePpm))
            );
        } else {
            // We have baseTokens. Convert `szX1e8` to base token budget. A simple decimals conversion here
            budget = uint64((szX1e8 * 10 ** (baseWeiD)) / 10 ** 8);
        }
    }

    /**
     * @notice The purpose of this function is best described by its return params. Given a budget and a price, determines
     * size to set, tokens to send, and min amount received.
     * @return szX1e8 size value to supply when sending a limit order to HyperCore
     * @return coreToSend the number of tokens to send for this trade to suceed; <= coreBudget
     * @return guaranteedCoreOut the ABSOLUTE MINIMUM that we're guaranteed to receive when the limit order fully settles
     */
    function _calcLOAmounts(
        uint64 coreBudget,
        uint64 pxX1e8,
        bool isBuy,
        uint64 feePpm,
        uint8 tokenHaveWeiD,
        uint8 tokenHaveSzD,
        uint8 tokenWantWeiD,
        uint8 tokenWantSzD
    ) internal pure returns (uint64 szX1e8, uint64 coreToSend, uint64 guaranteedCoreOut) {
        if (isBuy) {
            return
                _calcLOAmountsBuy(coreBudget, pxX1e8, tokenHaveWeiD, tokenHaveSzD, tokenWantWeiD, tokenWantSzD, feePpm);
        } else {
            return
                _calcLOAmountsSell(
                    coreBudget,
                    pxX1e8,
                    tokenWantWeiD,
                    tokenWantSzD,
                    tokenHaveWeiD,
                    tokenHaveSzD,
                    feePpm
                );
        }
    }

    /**
     * @notice Given the quote budget and the price, this function calculates the size of the buy limit order to set
     * as well as the minimum amount of out token to expect. This calculation is based on the HIP-1 spot trading formula.
     * Source: https://hyperliquid.gitbook.io/hyperliquid-docs/hyperliquid-improvement-proposals-hips/hip-1-native-token-standard#spot-trading
     * @param quoteBudget The budget of the quote in base token.
     * @param pxX1e8 The price of the quote token in base token.
     * @param quoteD The decimals of the quote token.
     * @param quoteSz The size decimals of the quote token.
     * @param baseD The decimals of the base token.
     * @param baseSz The size decimals of the base token.
     * @param feePpm The fee in ppm that is applied to the quote.
     * @return szX1e8 The size of the limit order to set.
     * @return tokensToSendCore The number of tokens to send for this trade to suceed.
     * @return minAmountOutCore The minimum amount of out token to expect.
     */
    function _calcLOAmountsBuy(
        uint64 quoteBudget,
        uint64 pxX1e8,
        uint8 quoteD,
        uint8 quoteSz,
        uint8 baseD,
        uint8 baseSz,
        uint64 feePpm
    ) internal pure returns (uint64 szX1e8, uint64 tokensToSendCore, uint64 minAmountOutCore) {
        uint256 px = (pxX1e8 * 10 ** (PX_D + quoteSz)) / 10 ** (8 + baseSz);
        // quoteD >= quoteSz always
        uint256 sz = (quoteBudget * (PPM_SCALAR - feePpm) * 10 ** PX_D) / (PPM_SCALAR * px * 10 ** (quoteD - quoteSz));
        // baseD >= baseSz always
        uint64 outBaseNet = uint64(sz * 10 ** (baseD - baseSz));
        szX1e8 = uint64((uint256(outBaseNet) * 10 ** 8) / 10 ** baseD);
        tokensToSendCore = quoteBudget;
        minAmountOutCore = outBaseNet;
    }

    /**
     * @notice Given the quote budget and the price, this function calculates the size of the sell limit order to set
     * as well as the minimum amount of out token to expect. This calculation is based on the HIP-1 spot trading formula.
     * Source: https://hyperliquid.gitbook.io/hyperliquid-docs/hyperliquid-improvement-proposals-hips/hip-1-native-token-standard#spot-trading
     * @param baseBudget The budget of the quote in base token.
     * @param pxX1e8 The price of the quote token in base token.
     * @param quoteD The decimals of the quote token.
     * @param quoteSz The size decimals of the quote token.
     * @param baseD The decimals of the base token.
     * @param baseSz The size decimals of the base token.
     * @param feePpm The fee in ppm that is applied to the quote.
     * @return szX1e8 The size of the limit order to set.
     * @return tokensToSendCore The number of tokens to send for this trade to suceed.
     * @return minAmountOutCore The minimum amount of out token to expect.
     */
    function _calcLOAmountsSell(
        uint64 baseBudget,
        uint64 pxX1e8,
        uint8 quoteD,
        uint8 quoteSz,
        uint8 baseD,
        uint8 baseSz,
        uint64 feePpm
    ) internal pure returns (uint64 szX1e8, uint64 tokensToSendCore, uint64 minAmountOutCore) {
        uint64 sz = uint64(baseBudget / 10 ** (baseD - baseSz));
        uint256 px = (pxX1e8 * 10 ** (PX_D + quoteSz)) / 10 ** (8 + baseSz);

        // quoteD >= quoteSz always
        uint64 outQuoteGross = uint64((px * sz * 10 ** (quoteD - quoteSz)) / 10 ** PX_D);
        uint64 outQuoteNet = uint64((outQuoteGross * (PPM_SCALAR - feePpm)) / PPM_SCALAR);
        szX1e8 = uint64((sz * 10 ** 8) / 10 ** baseSz);
        tokensToSendCore = baseBudget;
        minAmountOutCore = outQuoteNet;
    }
}
