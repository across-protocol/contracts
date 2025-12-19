// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title SharedDecimalsLib
 * @notice Copied from LZ implementation here:
 * `https://github.com/LayerZero-Labs/devtools/blob/16daaee36fe802d11aa99b89c29bb74447354483/packages/oft-evm/contracts/OFTCore.sol#L364`
 * Code was not modified beyond removing unrelated OFT/OApp concerns.
 */
abstract contract SharedDecimalsLib {
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
    uint8 internal immutable _sharedDecimals;

    /**
     * @dev Constructor.
     * @param _localDecimals The decimals of the token on the local chain (this chain).
     * @param _sharedDecimalsArg The shared decimals used by the OFT.
     */
    constructor(uint8 _localDecimals, uint8 _sharedDecimalsArg) {
        _sharedDecimals = _sharedDecimalsArg;
        if (_localDecimals < _sharedDecimalsArg) revert InvalidLocalDecimals();
        decimalConversionRate = 10 ** (_localDecimals - _sharedDecimalsArg);
    }

    /**
     * @dev Retrieves the shared decimals of the OFT.
     * @return The shared decimals of the OFT.
     *
     * @dev Sets an implicit cap on the amount of tokens, over uint64.max() will need some sort of outbound cap / totalSupply cap
     * Lowest common decimal denominator between chains.
     * Defaults to 6 decimal places to provide up to 18,446,744,073,709.551615 units (max uint64).
     * For tokens exceeding this totalSupply(), they will need to override the sharedDecimals function with something smaller.
     * ie. 4 sharedDecimals would be 1,844,674,407,370,955.1615
     */
    function sharedDecimals() public view virtual returns (uint8) {
        return _sharedDecimals;
    }

    /**
     * @dev Internal function to remove dust from the given local decimal amount.
     * @param _amountLD The amount in local decimals.
     * @return amountLD The amount after removing dust.
     *
     * @dev Prevents the loss of dust when moving amounts between chains with different decimals.
     * @dev eg. uint(123) with a conversion rate of 100 becomes uint(100).
     */
    function _removeDust(uint256 _amountLD) internal view virtual returns (uint256 amountLD) {
        return (_amountLD / decimalConversionRate) * decimalConversionRate;
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
