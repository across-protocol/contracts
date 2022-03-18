// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface LpTokenFactoryInterface {
    function createLpToken(address l1Token) external returns (address);
}
