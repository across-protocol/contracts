// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/presets/ERC1155PresetMinterPauser.sol";

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract MintableERC1155 is ERC1155, Ownable {
    mapping(uint256 => string) public _tokenURIs;

    event Airdrop(address caller, uint256 tokenId, address[] recipients, uint256 amount);

    // solhint-disable-next-line
    constructor() ERC1155("") {}

    /**
     * @dev Creates `amount` new tokens for `recipients` of token type `tokenId`.
     * @param recipients List of airdrop recipients.
     * @param tokenId Token type to airdrop.
     * @param amount Amount of token types to airdrop.
     *
     * NOTE: Call might run out of gas if `recipients` arg too long. Might need to chunk up the list.
     */
    function airdrop(
        uint256 tokenId,
        address[] memory recipients,
        uint256 amount
    ) public onlyOwner {
        for (uint256 i = 0; i < recipients.length; i++) {
            _mint(recipients[i], tokenId, amount, "");
        }
        emit Airdrop(_msgSender(), tokenId, recipients, amount);
    }

    /**
     * @dev Sets the URI for token of type `tokenId` to `tokenURI`.
     * @param tokenId Token type to set `tokenURI` for.
     * @param tokenURI URI of token metadata.
     */
    function setTokenURI(uint256 tokenId, string memory tokenURI) external onlyOwner {
        _tokenURIs[tokenId] = tokenURI;
    }

    /**
     * @dev Instead of returning the same URI for *all* token types, we return the uri set by
     * `setTokenURI` to allow IPFS URIs for all token types.
     * @param tokenId Token type to retrieve metadata URI for.
     */
    function uri(uint256 tokenId) public view virtual override returns (string memory) {
        return _tokenURIs[tokenId];
    }
}
