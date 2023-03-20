// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/**
 * @title MintableERC1155
 * @notice Ownable contract enabling owner to airdrop many recipients the same token ID at once
 */
contract MintableERC1155 is ERC1155, Ownable {
    // Maps `tokenId` to metadata URI `tokenURI`
    mapping(uint256 => string) public _tokenURIs;

    event Airdrop(address caller, uint256 tokenId, address[] recipients, uint256 amount);

    // We are passing an empty string as the `baseURI` because we use `_tokenURIs` instead
    // to allow for IPFS URIs.
    // solhint-disable-next-line
    constructor() ERC1155("") {}

    /**
     * @notice Creates `amount` new tokens for `recipients` of token type `tokenId`.
     * @dev Call might run out of gas if `recipients` arg too long. Might need to chunk up the list.
     * @param recipients List of airdrop recipients.
     * @param tokenId Token type to airdrop.
     * @param amount Amount of token types to airdrop.
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
     * @notice Sets the URI for token of type `tokenId` to `tokenURI`.
     * @param tokenId Token type to set `tokenURI` for.
     * @param tokenURI URI of token metadata.
     */
    function setTokenURI(uint256 tokenId, string memory tokenURI) external onlyOwner {
        require(bytes(_tokenURIs[tokenId]).length == 0, "uri already set");

        _tokenURIs[tokenId] = tokenURI;
        emit URI(tokenURI, tokenId);
    }

    /**
     * @notice Returns metadata URI of token type `tokenId`.
     * @dev Instead of returning the same URI for *all* token types, we return the uri set by
     * `setTokenURI` to allow IPFS URIs for all token types.
     * @param tokenId Token type to retrieve metadata URI for.
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        return _tokenURIs[tokenId];
    }
}
