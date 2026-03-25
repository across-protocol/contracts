// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "./LimitOrderCalcUtils.sol";

/*
@notice Thin CLI wrapper exposing public functions for calling internal library helpers from the command line.
Usage example (Selling USDT0 into USDC):

forge script script/mintburn/LimitOrderCalcCli.s.sol:LimitOrderCalcCli \
  --sig "calcLOAmounts(uint64,uint64,bool,uint64,uint8,uint8,uint8,uint8)" \
  100000000 99990000 false 80 8 2 8 8
*/
contract LimitOrderCalcCli is Script {
    // Suggested price with discount/premium
    function calcSuggestedPrice(
        uint64 spotX1e8,
        bool isBuy,
        uint32 suggestedDiscountBps
    ) external view returns (uint64 limitPriceX1e8) {
        return LimitOrderCalcUtils._getSuggestedPriceX1e8(spotX1e8, isBuy, suggestedDiscountBps);
    }

    // Remaining LO budget given size/price/fees
    function calcRemainingLOBudget(
        uint64 pxX1e8,
        uint64 szX1e8,
        bool isBuy,
        uint64 feePpm,
        uint8 weiDecimalsTokenHave,
        uint8 weiDecimalsTokenWant
    ) external pure returns (uint64 budget) {
        return
            LimitOrderCalcUtils._calcRemainingLOBudget(
                pxX1e8,
                szX1e8,
                isBuy,
                feePpm,
                weiDecimalsTokenHave,
                weiDecimalsTokenWant
            );
    }

    // Calculate limit order size given budget and desired price
    function calcLOAmounts(
        uint64 coreBudget,
        uint64 pxX1e8,
        bool isBuy,
        uint64 feePpm,
        uint8 tokenHaveWeiD,
        uint8 tokenHaveSzD,
        uint8 tokenWantWeiD,
        uint8 tokenWantSzD
    ) external pure returns (uint64 szX1e8, uint64 coreToSend, uint64 guaranteedCoreOut) {
        return
            LimitOrderCalcUtils._calcLOAmounts(
                coreBudget,
                pxX1e8,
                isBuy,
                feePpm,
                tokenHaveWeiD,
                tokenHaveSzD,
                tokenWantWeiD,
                tokenWantSzD
            );
    }
}
