// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice Ethereum L1 specific SpokePool. Used on Ethereum L1 to facilitate L2->L1 transfers.
 */
contract Ethereum_SpokePool is SpokePool, Ownable {
    /**
     * @notice Construct the Ethereum SpokePool.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wethAddress Weth address for this network to set.
     * @param timerAddress Timer address to set.
     */
    constructor(
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(msg.sender, _hubPool, _wethAddress, timerAddress) {}

    /**************************************
     *          INTERNAL FUNCTIONS        *
     **************************************/

    // Admin is simply owner which should be same account that owns the HubPool deployed on this network. A core
    // assumption of this contract system is that the HubPool is deployed on Ethereum.
    function _requireAdminSender() internal override onlyOwner {}
}
