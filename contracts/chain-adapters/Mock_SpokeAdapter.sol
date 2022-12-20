//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../interfaces/SpokeAdapterInterface.sol";

/**
 * @title MockSpokeAdapter
 * @notice Implements abstract contract for testing.
 */
contract Mock_SpokeAdapter is SpokeAdapterInterface {
    event BridgeTokensToHubPoolCalled(uint256 amountToReturn, address l2TokenAddress);

    // solhint-disable-next-line no-empty-blocks
    function bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) external override {
        emit BridgeTokensToHubPoolCalled(amountToReturn, l2TokenAddress);
    }
}
