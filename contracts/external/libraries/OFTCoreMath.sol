// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title OFTCoreMath
 * @notice Copied from LZ implementation here:
 * `https://github.com/LayerZero-Labs/devtools/blob/16daaee36fe802d11aa99b89c29bb74447354483/packages/oft-evm/contracts/OFTCore.sol#L364`
 * Code was not modified beyond adding `uint8 _sharedDecimals` to constructor args and substituting `sharedDecimals()` calls with it
 */
abstract contract OFTCoreMath {
    error InvalidLocalDecimals();
    error AmountSDOverflowed(uint256 amountSD);

    // @notice Provides a conversion rate when swapping between denominations of SD and LD
    //      - shareDecimals == SD == shared Decimals
    //      - localDecimals == LD == local decimals
    // @dev Considers that tokens have different decimal amounts on various chains.
    // @dev eg.
    //  For a token
    //      - locally with 4 decimals --> 1.2345 => uint(12345)
    //      - remotely with 2 decimals --> 1.23 => uint(123)
    //      - The conversion rate would be 10 ** (4 - 2) = 100
    //  @dev If you want to send 1.2345 -> (uint 12345), you CANNOT represent that value on the remote,
    //  you can only display 1.23 -> uint(123).
    //  @dev To preserve the dust that would otherwise be lost on that conversion,
    //  we need to unify a denomination that can be represented on ALL chains inside of the OFT mesh
    uint256 public immutable decimalConversionRate;

    /**
     * @dev Constructor.
     * @param _localDecimals The decimals of the token on the local chain (this chain).
     * @param _sharedDecimals The shared decimals used by the OFT.
     */
    constructor(uint8 _localDecimals, uint8 _sharedDecimals) {
        if (_localDecimals < _sharedDecimals) revert InvalidLocalDecimals();
        decimalConversionRate = 10 ** (_localDecimals - _sharedDecimals);
    }

    /**
     * @dev Internal function to convert an amount from shared decimals into local decimals.
     * @param _amountSD The amount in shared decimals.
     * @return amountLD The amount in local decimals.
     */
    function _toLD(uint64 _amountSD) internal view virtual returns (uint256 amountLD) {
        return _amountSD * decimalConversionRate;
    }

    /**
     * @dev Internal function to convert an amount from local decimals into shared decimals.
     * @param _amountLD The amount in local decimals.
     * @return amountSD The amount in shared decimals.
     *
     * @dev Reverts if the _amountLD in shared decimals overflows uint64.
     * @dev eg. uint(2**64 + 123) with a conversion rate of 1 wraps around 2**64 to uint(123).
     */
    function _toSD(uint256 _amountLD) internal view virtual returns (uint64 amountSD) {
        uint256 _amountSD = _amountLD / decimalConversionRate;
        if (_amountSD > type(uint64).max) revert AmountSDOverflowed(_amountSD);
        return uint64(_amountSD);
    }
}
