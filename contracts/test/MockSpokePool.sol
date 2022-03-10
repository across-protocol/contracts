//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../SpokePool.sol";
import "../SpokePoolInterface.sol";

/**
 * @title MockSpokePool
 * @notice Implements abstract contract for testing.
 */
contract MockSpokePool is SpokePoolInterface, SpokePool {
    uint256 chainId_;

    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress,
        uint256 _chainId
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress) {
        chainId_ = _chainId;
    }

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {}

    function _requireAdminSender() internal override {}

    function chainId() public view override(SpokePool, SpokePoolInterface) returns (uint256) {
        // If chainId_ is set then return it, else do nothing and return the parent chainId().
        return chainId_ == 0 ? super.chainId() : chainId_;
    }
}
