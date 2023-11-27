// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "../Ovm_SpokePool.sol";

/**
 * @notice Mock Optimism Spoke pool allowing deployer to override constructor params.
 */
contract MockOptimism_SpokePool is Ovm_SpokePool {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _wrappedNativeTokenAddress) Ovm_SpokePool(_wrappedNativeTokenAddress) {}

    function initialize(
        address l2Eth,
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool
    ) public initializer {
        __OvmSpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, l2Eth);
    }
}
