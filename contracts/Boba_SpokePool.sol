// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./Optimism_SpokePool.sol";

/**
 * @notice Boba Spoke pool. Exact copy of the Optimism_SpokePool with no modifications.
 */
contract Boba_SpokePool is Optimism_SpokePool {
    /**
     * @notice Construct the OVM Boba SpokePool.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wrappedNativeToken Address of the native token on this chain.
     * @param timerAddress Timer address to set.
     */
    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address _wrappedNativeToken,
        address timerAddress
    ) Optimism_SpokePool(_crossDomainAdmin, _hubPool, _wrappedNativeToken, timerAddress) {}
}
