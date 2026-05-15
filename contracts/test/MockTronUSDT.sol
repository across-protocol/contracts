// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { ERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";

/**
 * @title MockTronUSDT
 * @notice Test mock that mirrors the Tron USDT bug: `transfer` moves balances correctly
 *         but always returns `false` on success. `transferFrom` and `approve` return
 *         `true` correctly per the standard.
 * @dev Set `blacklisted[addr]` to make transfers involving that address revert, simulating
 *      Tether's `notBlacklisted` modifier and the "actual failure" scenario.
 */
contract MockTronUSDT is ERC20 {
    mapping(address => bool) public blacklisted;

    constructor() ERC20("Tron USDT", "USDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlacklisted(address account, bool isBlacklisted) external {
        blacklisted[account] = isBlacklisted;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[msg.sender] && !blacklisted[to], "blacklisted");
        _transfer(msg.sender, to, amount);
        return false;
    }
}
