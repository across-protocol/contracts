// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { HLConstants } from "./HLConstants.sol";
import { PrecompileLib } from "../PrecompileLib.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library HLConversions {
    error HLConversions__InvalidToken(uint64 token);

    /**
     * @dev Converts an EVM amount to a Core (wei) amount, handling both positive and negative extra decimals
     * Note: If evmExtraWeiDecimals > 0, and evmAmount < 10**evmExtraWeiDecimals, the result will be 0
     */
    function evmToWei(uint64 token, uint256 evmAmount) internal view returns (uint64) {
        PrecompileLib.TokenInfo memory info = PrecompileLib.tokenInfo(uint32(token));

        if (info.evmContract != address(0)) {
            if (info.evmExtraWeiDecimals > 0) {
                uint256 amount = evmAmount / (10 ** uint8(info.evmExtraWeiDecimals));
                return SafeCast.toUint64(amount);
            } else if (info.evmExtraWeiDecimals < 0) {
                uint256 amount = evmAmount * (10 ** uint8(-info.evmExtraWeiDecimals));
                return SafeCast.toUint64(amount);
            }
        } else if (HLConstants.isHype(token)) {
            return SafeCast.toUint64(evmAmount / (10 ** HLConstants.HYPE_EVM_EXTRA_DECIMALS));
        }

        revert HLConversions__InvalidToken(token);
    }

    function weiToEvm(uint64 token, uint64 amountWei) internal view returns (uint256) {
        PrecompileLib.TokenInfo memory info = PrecompileLib.tokenInfo(uint32(token));
        if (info.evmContract != address(0)) {
            if (info.evmExtraWeiDecimals > 0) {
                return (uint256(amountWei) * (10 ** uint8(info.evmExtraWeiDecimals)));
            } else if (info.evmExtraWeiDecimals < 0) {
                return amountWei / (10 ** uint8(-info.evmExtraWeiDecimals));
            }
        } else if (HLConstants.isHype(token)) {
            return (uint256(amountWei) * (10 ** HLConstants.HYPE_EVM_EXTRA_DECIMALS));
        }

        revert HLConversions__InvalidToken(token);
    }

    function szToWei(uint64 token, uint64 sz) internal view returns (uint64) {
        PrecompileLib.TokenInfo memory info = PrecompileLib.tokenInfo(uint32(token));
        return sz * uint64(10 ** (info.weiDecimals - info.szDecimals));
    }

    function weiToSz(uint64 token, uint64 amountWei) internal view returns (uint64) {
        PrecompileLib.TokenInfo memory info = PrecompileLib.tokenInfo(uint32(token));
        return amountWei / uint64(10 ** (info.weiDecimals - info.szDecimals));
    }

    // for USDC between spot and perp
    function weiToPerp(uint64 amountWei) internal pure returns (uint64) {
        return amountWei / 10 ** 2;
    }

    function perpToWei(uint64 perpAmount) internal pure returns (uint64) {
        return perpAmount * 10 ** 2;
    }

    function spotToAssetId(uint64 spot) internal pure returns (uint64) {
        return spot + 10000;
    }

    function assetToSpotId(uint64 asset) internal pure returns (uint64) {
        return asset - 10000;
    }
}
