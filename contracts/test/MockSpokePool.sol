//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../SpokePool.sol";

/**
 * @title MockSpokePool
 * @notice Implements admin internal methods to test internal logic.
 */
contract MockSpokePool is SpokePool {
    constructor(
        address _wethAddress,
        uint64 _depositQuoteTimeBuffer,
        address timerAddress
    ) SpokePool(_wethAddress, _depositQuoteTimeBuffer, timerAddress) {}

    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enable
    ) public {
        _setEnableRoute(originToken, destinationChainId, enable);
    }

    function setDepositQuoteTimeBuffer(uint64 buffer) public {
        _setDepositQuoteTimeBuffer(buffer);
    }
}
