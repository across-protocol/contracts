//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts5/interfaces/IERC1271.sol";
import "@openzeppelin/contracts5/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts5/access/Ownable.sol";

/**
 * @title MockERC1271
 * @notice Implements mocked ERC1271 contract for testing.
 */
contract MockERC1271 is IERC1271, Ownable {
    constructor(address originalOwner) Ownable(originalOwner) {}

    function isValidSignature(bytes32 hash, bytes memory signature) public view override returns (bytes4 magicValue) {
        return ECDSA.recover(hash, signature) == owner() ? this.isValidSignature.selector : bytes4(0);
    }
}
