// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "../Ovm_SpokePool.sol";

/**
 * @notice Mock Optimism Spoke pool allowing deployer to override constructor params.
 */
contract MockOptimism_SpokePool is Ovm_SpokePool {
    address private wethAddress;

    function initialize(
        address l2Eth,
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress
    ) public initializer {
        __OvmSpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, l2Eth);
        wethAddress = _wethAddress;
    }

    function wrappedNativeToken() public view override returns (WETH9Interface) {
        return WETH9Interface(wethAddress);
    }
}
