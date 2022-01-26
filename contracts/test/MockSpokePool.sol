//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../SpokePool.sol";


/**
 * @title MockSpokePool
 * @notice Implements admin internal methods to test internal logic.
 */
contract MockSpokePool is SpokePool {

    constructor(
        address timerAddress,
        address _wethAddress,
        uint64 _depositQuoteTimeBuffer
    ) SpokePool(timerAddress, _wethAddress, _depositQuoteTimeBuffer) {}

    function whitelistRoute(
        address originToken,
        address destinationToken,
        uint256 destinationChainId
    ) public {
        _whitelistRoute(originToken, destinationToken, destinationChainId);
    }

    function setDepositQuoteTimeBuffer(uint64 buffer) public {
        _setDepositQuoteTimeBuffer(buffer);
    }

}
