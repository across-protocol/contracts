//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../SpokePool.sol";
import "../SpokePoolInterface.sol";

/**
 * @title MockSpokePool
 * @notice Implements admin internal methods to test internal logic.
 */
contract MockSpokePool is SpokePoolInterface, SpokePool {
    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress,
        uint32 _depositQuoteTimeBuffer
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress, _depositQuoteTimeBuffer) {}

    function setCrossDomainAdmin(address newCrossDomainAdmin) public override {
        _setCrossDomainAdmin(newCrossDomainAdmin);
    }

    function setHubPool(address newHubPool) public override {
        _setHubPool(newHubPool);
    }

    function setEnableRoute(
        address originToken,
        uint32 destinationChainId,
        bool enable
    ) public override {
        _setEnableRoute(originToken, destinationChainId, enable);
    }

    function setDepositQuoteTimeBuffer(uint32 buffer) public override {
        _setDepositQuoteTimeBuffer(buffer);
    }

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionRoot, bytes32 slowRelayFulfillmentRoot)
        public
        override
    {
        _initializeRelayerRefund(relayerRepaymentDistributionRoot, slowRelayFulfillmentRoot);
    }

    function _bridgeTokensToHubPool(DestinationDistributionLeaf memory distributionLeaf) internal override {}
}
