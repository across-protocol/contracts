// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Ovm_SpokePool.sol";

/**
 * @notice Boba Spoke pool. Note that the l2ETH and l2WETH are the opposite as that in Optimism.
 */
contract Boba_SpokePool is Ovm_SpokePool {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    )
        Ovm_SpokePool(
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            IERC20(address(0)),
            ITokenMessenger(address(0))
        )
    {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the OVM Boba SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _withdrawalRecipient Address which receives token withdrawals. Can be changed by admin. For Spoke Pools on L2, this will
     * likely be the hub pool.
     */
    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        __OvmSpokePool_init(
            _initialDepositId,
            _crossDomainAdmin,
            _withdrawalRecipient,
            0x4200000000000000000000000000000000000006
        );
    }
}
