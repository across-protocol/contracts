//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../SpokePool.sol";
import "../SpokePoolInterface.sol";

/**
 * @title MockSpokePool
 * @notice Implements admin internal methods to test internal logic.
 */
contract MockSpokePool is SpokePoolInterface, SpokePool {
    address public override crossDomainAdmin;

    constructor(
        address _wethAddress,
        uint64 _depositQuoteTimeBuffer,
        address timerAddress
    ) SpokePool(_wethAddress, _depositQuoteTimeBuffer, timerAddress) {}

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

    function setCrossDomainAdmin(address newCrossDomainAdmin) public override {
        crossDomainAdmin = newCrossDomainAdmin;
    }
}
