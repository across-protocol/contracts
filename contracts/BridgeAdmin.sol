// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./interfaces/BridgeAdminInterface.sol";

contract BridgeAdmin is BridgeAdminInterface {
    // Finder used to point to latest OptimisticOracle and other DVM contracts.
    address public finder;

    constructor(address _finder) {
        finder = _finder;
    }
}
