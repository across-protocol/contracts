// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/TestnetERC20.sol";

/**
 * @notice Simulated ERC20 for use in testing bridge transfers.
 */
contract ERC20Test is TestnetERC20 {
    constructor() TestnetERC20("ERC20 Test", "ERC20_TEST", 18) {} // solhint-disable-line no-empty-blocks
}
