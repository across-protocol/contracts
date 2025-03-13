// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/ExpandedERC20.sol";

contract ExpandedERC20WithBlacklist is ExpandedERC20 {
    mapping(address => bool) public isBlackListed;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) ExpandedERC20(name, symbol, decimals) {}

    function setBlacklistStatus(address account, bool status) external {
        isBlackListed[account] = status;
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(!isBlackListed[to], "Recipient is blacklisted");
        super._beforeTokenTransfer(from, to, amount);
    }
}
