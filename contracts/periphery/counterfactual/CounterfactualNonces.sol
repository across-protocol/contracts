// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title CounterfactualNonces
 * @notice Shared single-use nonce tracking for leaf implementations whose fee signature is the sole
 *         authorization (no periphery to consume a nonce): SpokePool and Vanilla CCTP.
 * @dev Runs under the proxy's delegatecall, so the used-nonce mapping lives in **each proxy's storage**
 *      (nonces are per-clone, like the dispatcher's `activeRoot`), in an ERC-7201 namespaced slot that
 *      cannot collide with the dispatcher's namespace. The namespace is shared by every impl using this
 *      mixin, so a nonce is single-use across all such routes of one proxy — nonces are random 32 bytes
 *      chosen by the off-chain signer, so collisions are a non-issue.
 *      **Every future implementation version MUST preserve this ERC-7201 storage layout.**
 * @custom:security-contact bugs@across.to
 */
abstract contract CounterfactualNonces {
    /// @custom:storage-location erc7201:across.counterfactual.nonces.storage
    struct NoncesStorage {
        mapping(bytes32 => bool) usedNonces;
    }

    // keccak256(abi.encode(uint256(keccak256("across.counterfactual.nonces.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant NONCES_STORAGE_LOCATION =
        0x6620ce368f04f685aa0153e5e3347c828611b4776c1dc36e5c44b4db1be22600;

    /// @dev The signature's nonce was already consumed on this proxy (replay).
    error InvalidNonce();

    /// @dev Consume `nonce` on this proxy; reverts `InvalidNonce` if already used. Call after signature
    ///      verification and before any external interaction.
    function _useNonce(bytes32 nonce) internal {
        NoncesStorage storage $ = _getNoncesStorage();
        if ($.usedNonces[nonce]) revert InvalidNonce();
        $.usedNonces[nonce] = true;
    }

    function _getNoncesStorage() private pure returns (NoncesStorage storage $) {
        assembly {
            $.slot := NONCES_STORAGE_LOCATION
        }
    }
}
