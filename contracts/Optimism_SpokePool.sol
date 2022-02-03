//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@eth-optimism/contracts/libraries/bridge/CrossDomainEnabled.sol";
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";
import "./SpokePool.sol";

/**
 * @notice OVM specific SpokePool.
 * @dev Uses OVM cross-domain-enabled logic for access control.
 */

contract Optimism_SpokePool is CrossDomainEnabled, SpokePool {
    // Address of the L1 contract that acts as the owner of this SpokePool.
    address public crossDomainAdmin;

    event SetXDomainAdmin(address indexed newAdmin);

    constructor(
        address _crossDomainAdmin,
        address _wethAddress,
        uint64 _depositQuoteTimeBuffer,
        address timerAddress
    )
        CrossDomainEnabled(Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER)
        SpokePool(_wethAddress, _depositQuoteTimeBuffer, timerAddress)
    {
        _setCrossDomainAdmin(_crossDomainAdmin);
    }

    /**************************************
     *          ADMIN FUNCTIONS           *
     **************************************/

    // TODO:
    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enable
    ) public onlyFromCrossDomainAccount(crossDomainAdmin) {
        _setEnableRoute(originToken, destinationChainId, enable);
    }

    // TODO:
    function setDepositQuoteTimeBuffer(uint64 buffer) public onlyFromCrossDomainAccount(crossDomainAdmin) {
        _setDepositQuoteTimeBuffer(buffer);
    }

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionProof)
        public
        onlyFromCrossDomainAccount(crossDomainAdmin)
    {
        _initializeRelayerRefund(relayerRepaymentDistributionProof);
    }

    /**************************************
     *         INTERNAL FUNCTIONS         *
     **************************************/

    function _setCrossDomainAdmin(address newCrossDomainAdmin) internal {
        require(newCrossDomainAdmin != address(0), "Bad bridge router address");
        crossDomainAdmin = newCrossDomainAdmin;
        emit SetXDomainAdmin(crossDomainAdmin);
    }
}
