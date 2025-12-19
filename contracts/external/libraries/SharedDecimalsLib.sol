// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title SharedDecimalsLib
 * @notice Library for handling shared decimals conversions for OFT bridging.
 * @dev Logic adapted from LayerZero's OFTCore.sol
 */
library SharedDecimalsLib {
    error InvalidLocalDecimals();
    error AmountSDOverflowed(uint256 amountSD);

    /**
     * @notice Convert an amount from local decimals into shared decimals.
     * @dev Internal function to convert an amount from local decimals into shared decimals.
     * @param _amountLD The amount in local decimals.
     * @param _localDecimals The decimals of the token on the local chain.
     * @param _sharedDecimals The shared decimals of the OFT.
     * @return amountSD The amount in shared decimals.
     *
     * @dev Reverts if the _amountLD in shared decimals overflows uint64.
     */
    function toSD(
        uint256 _amountLD,
        uint8 _localDecimals,
        uint8 _sharedDecimals
    ) internal pure returns (uint64 amountSD) {
        if (_localDecimals < _sharedDecimals) revert InvalidLocalDecimals();
        uint256 conversionRate = 10 ** (_localDecimals - _sharedDecimals);
        uint256 _amountSD = _amountLD / conversionRate;
        if (_amountSD > type(uint64).max) revert AmountSDOverflowed(_amountSD);
        return uint64(_amountSD);
    }

    /**
     * @notice Convert an amount from shared decimals into local decimals.
     * @dev Internal function to convert an amount from shared decimals into local decimals.
     * @param _amountSD The amount in shared decimals.
     * @param _localDecimals The decimals of the token on the local chain.
     * @param _sharedDecimals The shared decimals of the OFT.
     * @return amountLD The amount in local decimals.
     */
    function toLD(
        uint64 _amountSD,
        uint8 _localDecimals,
        uint8 _sharedDecimals
    ) internal pure returns (uint256 amountLD) {
        if (_localDecimals < _sharedDecimals) revert InvalidLocalDecimals();
        uint256 conversionRate = 10 ** (_localDecimals - _sharedDecimals);
        return uint256(_amountSD) * conversionRate;
    }

    /**
     * @notice Remove dust from the given local decimal amount.
     * @dev Internal function to remove dust from the given local decimal amount.
     * @param _amountLD The amount in local decimals.
     * @param _localDecimals The decimals of the token on the local chain.
     * @param _sharedDecimals The shared decimals of the OFT.
     * @return amountLD The amount after removing dust.
     */
    function removeDust(
        uint256 _amountLD,
        uint8 _localDecimals,
        uint8 _sharedDecimals
    ) internal pure returns (uint256 amountLD) {
        if (_localDecimals < _sharedDecimals) revert InvalidLocalDecimals();
        uint256 conversionRate = 10 ** (_localDecimals - _sharedDecimals);
        return (_amountLD / conversionRate) * conversionRate;
    }
}
