// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./interfaces/LpTokenFactoryInterface.sol";

import "@uma/core/contracts/common/implementation/ExpandedERC20.sol";

/**
 * @notice Factory to create new LP ERC20 tokens that represent a liquidity provider's position. HubPool is the
 * intended client of this contract.
 */
contract LpTokenFactory is LpTokenFactoryInterface {
    /**
     * @notice Deploys new LP token for L1 token. Sets caller as minter and burner of token.
     * @param l1Token L1 token to name in LP token name.
     * @return address of new LP token.
     */
    function createLpToken(address l1Token) public returns (address) {
        ExpandedERC20 lpToken = new ExpandedERC20(
            _append("Across ", IERC20Metadata(l1Token).name(), " LP Token"), // LP Token Name
            _append("Av2-", IERC20Metadata(l1Token).symbol(), "-LP"), // LP Token Symbol
            IERC20Metadata(l1Token).decimals() // LP Token Decimals
        );
        lpToken.addMinter(msg.sender); // Set the caller as the LP Token's minter.
        lpToken.addBurner(msg.sender); // Set the caller as the LP Token's burner.

        return address(lpToken);
    }

    function _append(
        string memory a,
        string memory b,
        string memory c
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b, c));
    }
}
