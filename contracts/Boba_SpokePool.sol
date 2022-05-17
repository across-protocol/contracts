// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./Optimism_SpokePool.sol";

/**
 * @notice Boba Spoke pool. Exact copy of the Optimism_SpokePool with no modifications except for them swapping around
 * the definition of the l2Eth and l2Weth vs Optimism.
 */
contract Boba_SpokePool is Optimism_SpokePool {
    /**
     * @notice Construct the OVM Boba SpokePool.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param timerAddress Timer address to set.
     */

    address public immutable override l2Eth = address(0x4200000000000000000000000000000000000006);
    address public immutable override wrappedNativeToken = (0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000);

    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address timerAddress
    ) Optimism_SpokePool(_crossDomainAdmin, _hubPool, timerAddress) {}
}
