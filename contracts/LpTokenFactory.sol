// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/LpTokenFactoryInterface.sol";

import "@uma/core/contracts/common/implementation/ExpandedERC20.sol";

/**
 * @notice Factory to create new LP ERC20 tokens that represent a liquidity provider's position. HubPool is the
 * intended client of this contract.
 * @custom:security-contact bugs@across.to
 */
contract LpTokenFactory is LpTokenFactoryInterface {
    /**
     * @notice Deploys new LP token for L1 token. Sets caller as minter and burner of token.
     * @param l1Token L1 token to name in LP token name.
     * @return address of new LP token.
     */
    function createLpToken(address l1Token) public returns (address) {
        ExpandedERC20 lpToken = new ExpandedERC20(
            _concatenate("Across V2 ", IERC20Metadata(l1Token).name(), " LP Token"), // LP Token Name
            _concatenate("Av2-", IERC20Metadata(l1Token).symbol(), "-LP"), // LP Token Symbol
            IERC20Metadata(l1Token).decimals() // LP Token Decimals
        );

        lpToken.addMinter(msg.sender); // Set the caller as the LP Token's minter.
        lpToken.addBurner(msg.sender); // Set the caller as the LP Token's burner.
        lpToken.resetOwner(msg.sender); // Set the caller as the LP Token's owner.

        return address(lpToken);
    }

    function _concatenate(
        string memory a,
        string memory b,
        string memory c
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b, c));
    }
}
