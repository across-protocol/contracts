//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../SpokePool.sol";


/**
 * @title MockSpokePool
 * @notice Implements admin internal methods to test internal logic.
 */
contract MockSpokePool is SpokePool {

    constructor(
        address timerAddress
    ) SpokePool(timerAddress) {}

    /**
     * @notice Whitelist an origin token <-> destination token route.
     */
    function whitelistRoute(
        address originToken,
        address destinationToken,
        bool isWethToken,
        uint256 destinationChainId
    ) public {
        _whitelistRoute(originToken, destinationToken, isWethToken, destinationChainId);
    }

    /**
     * @notice Enable/disable deposits for a whitelisted origin token.
     */
    function setEnableDeposits(address originToken, uint256 destinationChainId, bool depositsEnabled) public {
        _setEnableDeposits(originToken, destinationChainId, depositsEnabled);
    }

}
