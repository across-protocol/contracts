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

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionProof) public override {
        _initializeRelayerRefund(relayerRepaymentDistributionProof);
    }

    function distributeRelayerRefund(
        uint256 relayerRefundId,
        MerkleLib.DestinationDistribution memory distributionLeaf,
        bytes32[] memory inclusionProof
    ) public override {
        _distributeRelayerRefund(relayerRefundId, distributionLeaf, inclusionProof);

        // TODO: Test bridging
    }
}
