// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @notice Sends cross chain tokens to from SpokePool to HubPool.
 */

interface SpokeAdapterInterface {
    function bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) external;
}
