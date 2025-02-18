// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @notice Factory to create new LP ERC20 tokens that represent a liquidity provider's position. HubPool is the
 * intended client of this contract.
 */
interface LpTokenFactoryInterface {
    /**
     * @notice Deploys new LP token for L1 token. Sets caller as minter and burner of token.
     * @param l1Token L1 token to name in LP token name.
     * @return address of new LP token.
     */
    function createLpToken(address l1Token) external returns (address);
}
