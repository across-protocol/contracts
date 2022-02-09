// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface LpTokenFactoryInterface {
    function createLpToken(address l1Token) external returns (address);
}
