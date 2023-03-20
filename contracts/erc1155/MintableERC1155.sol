// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/presets/ERC1155PresetMinterPauser.sol";

contract MintableERC1155 is ERC1155PresetMinterPauser {
    mapping(uint256 => string) public _tokenURIs;

    event Airdrop(address caller, uint256 tokenId, address[] recipients, uint256[] amounts);

    constructor() ERC1155PresetMinterPauser("") {}

    /**
     * @dev Creates `amounts[i]` new tokens for `recipients[i]` of toke type `tokenId`.
     */
    function airdrop(
        uint256 tokenId,
        address[] memory recipients,
        uint256[] memory amounts
    ) public {
        require(recipients.length == amounts.length, "MintableERC1155: recipients and amounts length mismatch");

        for (uint256 i = 0; i < recipients.length; i++) {
            mint(recipients[i], tokenId, amounts[i], "");
        }
        emit Airdrop(_msgSender(), tokenId, recipients, amounts);
    }

    /**
     * @dev Sets the URI for token of type `tokenId` to `tokenURI`.
     */
    function setTokenURI(uint256 tokenId, string memory tokenURI) external {
        require(hasRole(MINTER_ROLE, _msgSender()), "ERC1155PresetMinterPauser: must have minter role to set uri");

        _tokenURIs[tokenId] = tokenURI;
    }

    /**
     * @dev Instead of returning the same URI for *all* token types, we return the uri set by
     * `setTokenURI` to allow IPFS URIs for token types.
     */
    function uri(uint256 tokenId) public view virtual override returns (string memory) {
        return _tokenURIs[tokenId];
    }
}
