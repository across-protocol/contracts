// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @notice Sends cross chain messages and tokens to contracts on a specific L2 network.
 */

interface AdapterInterface {
    event MessageRelayed(address target, bytes message);

    event TokensRelayed(address l1Token, address l2Token, uint256 amount, address to);

    function relayMessage(address target, bytes calldata message) external payable;

    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable;
}
