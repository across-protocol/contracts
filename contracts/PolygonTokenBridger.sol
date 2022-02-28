// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Lockable.sol";

// ERC20s (on polygon) compatible with polygon's bridge have a withdraw method.
interface PolygonIERC20 is IERC20 {
    function withdraw(uint256 amount) external;
}

// Because Polygon only allows withdrawals from a particular address to go to that same address on mainnet, we need to
// have some sort of contract that can guarantee identical addresses on Polygon and Ethereum.
// Note: this contract is intended to be completely immutable, so it's guaranteed that the contract on each side is
// configured identically as long as it is created via create2. create2 is an alternative creation method that uses
// a different address determination mechanism from normal create.
// Normal create: address = hash(deployer_address, deployer_nonce)
// create2:       address = hash(0xFF, sender, salt, bytecode)
// This ultimately allows create2 to generate deterministic addresses that don't depend on the transaction count of the
// sender.
contract PolygonTokenBridger is Lockable {
    using SafeERC20 for PolygonIERC20;
    using SafeERC20 for IERC20;

    address public immutable destination;

    constructor(address _destination) {
        destination = _destination;
    }

    // Polygon side.
    function send(PolygonIERC20 token, uint256 amount) public nonReentrant {
        token.safeTransferFrom(msg.sender, address(this), amount);
        token.withdraw(amount);
    }

    // Mainnet side.
    function retrieve(IERC20 token) public nonReentrant {
        token.safeTransfer(destination, token.balanceOf(address(this)));
    }
}
