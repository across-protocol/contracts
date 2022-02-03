// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @notice Sends cross chain messages and tokens to contracts on a specific L2 network.
 */

interface AdapterInterface {
    function relayMessage(address target, bytes memory message) external payable;

    function relayTokens(
        address l1Token,
        uint256 amount,
        address to
    ) external payable;
}
