// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/merkle-distributor/implementation/MerkleDistributor.sol";

/**
 * @title  Extended MerkleDistributor contract.
 * @notice Adds additional constraints governing who can claim leaves from merkle windows.
 */
contract AcrossMerkleDistributor is MerkleDistributor {
    // Addresses that can claim on user's behalf. Useful to get around the requirement that claim receipient
    // must also be claimer.
    mapping(address => bool) public whitelistedClaimers;

    /****************************************
     *                EVENTS
     ****************************************/
    event WhitelistedClaimer(address indexed claimer, bool indexed whitelist);

    /****************************
     *      ADMIN FUNCTIONS
     ****************************/

    /**
     * @notice Updates whitelisted claimer status.
     * @dev Callable only by owner.
     * @param newContract Reset claimer contract to this address.
     * @param whitelist True to whitelist claimer, False otherwise.
     */
    function whitelistClaimer(address newContract, bool whitelist) external onlyOwner {
        whitelistedClaimers[newContract] = whitelist;
        emit WhitelistedClaimer(newContract, whitelist);
    }

    /****************************
     *    NON-ADMIN FUNCTIONS
     ****************************/

    /**
     * @notice Batch claims to reduce gas versus individual submitting all claims. Method will fail
     *         if any individual claims within the batch would fail.
     * @dev    All claim recipients must be equal to msg.sender or claimer must be whitelisted.
     * @param claims array of claims to claim.
     */
    function claimMulti(Claim[] memory claims) public override {
        if (!whitelistedClaimers[msg.sender]) {
            uint256 claimCount = claims.length;
            for (uint256 i = 0; i < claimCount; i++) {
                require(claims[i].account == msg.sender, "invalid claimer");
            }
        }
        super.claimMulti(claims);
    }

    /**
     * @notice Claim amount of reward tokens for account, as described by Claim input object.
     * @dev    Claim recipient must be equal to msg.sender or caller must be whitelisted.
     * @param _claim claim object describing amount, accountIndex, account, window index, and merkle proof.
     */
    function claim(Claim memory _claim) public override {
        require(whitelistedClaimers[msg.sender] || _claim.account == msg.sender, "invalid claimer");
        super.claim(_claim);
    }
}
