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
        uint64 _depositQuoteTimeBuffer,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, _depositQuoteTimeBuffer, timerAddress) {}

    function setCrossDomainAdmin(address newCrossDomainAdmin) public override {
        _setCrossDomainAdmin(newCrossDomainAdmin);
    }

    function setHubPool(address newHubPool) public override {
        _setHubPool(newHubPool);
    }

    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enable
    ) public override {
        _setEnableRoute(originToken, destinationChainId, enable);
    }

    function setDepositQuoteTimeBuffer(uint64 buffer) public override {
        _setDepositQuoteTimeBuffer(buffer);
    }

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionRoot, bytes32 relayDataRoot) public override {
        _initializeRelayerRefund(relayerRepaymentDistributionRoot, relayDataRoot);
    }

    function _bridgeTokensToHubPool(MerkleLib.DestinationDistribution memory distributionLeaf) internal override {}
}
