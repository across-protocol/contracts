// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/ExpandedERC20.sol";
import "../PolygonTokenBridger.sol";

/**
 * @notice Simulated Polygon ERC20 for use in testing PolygonTokenBridger.
 */
contract PolygonERC20Test is ExpandedERC20 {
    constructor() ExpandedERC20("Polygon Test", "POLY_TEST", 18) {} // solhint-disable-line no-empty-blocks

    function withdraw(uint256 amount) public {
        _burn(msg.sender, amount);
    }
}
