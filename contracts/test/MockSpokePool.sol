//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../SpokePool.sol";
import "../SpokePoolInterface.sol";

/**
 * @title MockSpokePool
 * @notice Implements abstract contract for testing.
 */
contract MockSpokePool is SpokePool {
    uint256 private chainId_;

    // solhint-disable-next-line no-empty-blocks
    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress) {} // solhint-disable-line no-empty-blocks

    // solhint-disable-next-line no-empty-blocks
    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {}

    function _requireAdminSender() internal override {} // solhint-disable-line no-empty-blocks

    function chainId() public view override(SpokePool) returns (uint256) {
        // If chainId_ is set then return it, else do nothing and return the parent chainId().
        return chainId_ == 0 ? super.chainId() : chainId_;
    }

    function setChainId(uint256 _chainId) public {
        chainId_ = _chainId;
    }
}
