// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/merkle-distributor/implementation/MerkleDistributor.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  Extended MerkleDistributor contract.
 * @notice Adds additional constraints governing who can claim leaves from merkle windows.
 */
contract AcrossMerkleDistributor is MerkleDistributor {
    using SafeERC20 for IERC20;

    // Addresses that can claim on user's behalf.
    mapping(address => bool) public whitelistedClaimers;

    /****************************************
     *                EVENTS
     ****************************************/
    event WhitelistedClaimer(address indexed claimer, bool indexed whitelist);
    event ClaimFor(
        address indexed caller,
        uint256 windowIndex,
        address indexed account,
        uint256 accountIndex,
        uint256 amount,
        address indexed rewardToken
    );

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
     * @dev    All claim recipients must be equal to msg.sender.
     * @param claims array of claims to claim.
     */
    function claimMulti(Claim[] memory claims) public override {
        uint256 claimCount = claims.length;
        for (uint256 i = 0; i < claimCount; i++) {
            require(claims[i].account == msg.sender, "invalid claimer");
        }
        super.claimMulti(claims);
    }

    /**
     * @notice Claim amount of reward tokens for account, as described by Claim input object.
     * @dev    Claim recipient must be equal to msg.sender.
     * @param _claim claim object describing amount, accountIndex, account, window index, and merkle proof.
     */
    function claim(Claim memory _claim) public override {
        require(_claim.account == msg.sender, "invalid claimer");
        super.claim(_claim);
    }

    /**
     * @notice Executes merkle leaf claim on behaf of user. This can only be called by a trusted
     *         claimer address. This function is designed to be called atomically with other transactions
     *         that ultimately return the claimed amount to the rightful recipient. For example,
     *         AcceleratingDistributor could call this function and then stake atomically on behalf of the user.
     * @dev    Caller must be in whitelistedClaimers struct set to "true".
     * @param _claim leaf to claim.
     */

    function claimFor(Claim memory _claim) public {
        require(whitelistedClaimers[msg.sender], "unwhitelisted claimer");
        _verifyAndMarkClaimed(_claim);
        merkleWindows[_claim.windowIndex].rewardToken.safeTransfer(msg.sender, _claim.amount);
        emit ClaimFor(
            msg.sender,
            _claim.windowIndex,
            _claim.account,
            _claim.accountIndex,
            _claim.amount,
            address(merkleWindows[_claim.windowIndex].rewardToken)
        );
    }
}
