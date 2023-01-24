//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../SpokePool.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title MockSpokePool
 * @notice Implements abstract contract for testing.
 */
contract MockSpokePool is SpokePool, OwnableUpgradeable {
    uint256 private chainId_;

    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address _timerAddress
    ) public initializer {
        __Ownable_init();
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, _wethAddress, _timerAddress);
    }

    // solhint-disable-next-line no-empty-blocks
    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {}

    function _requireAdminSender() internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    function chainId() public view override(SpokePool) returns (uint256) {
        // If chainId_ is set then return it, else do nothing and return the parent chainId().
        return chainId_ == 0 ? super.chainId() : chainId_;
    }

    function setChainId(uint256 _chainId) public {
        chainId_ = _chainId;
    }
}
