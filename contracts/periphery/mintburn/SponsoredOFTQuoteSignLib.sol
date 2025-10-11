// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SponsoredOFTQuoteSignedParams } from "./SponsoredOftMintBurnStructs.sol";

/// @notice Raw keccak256-based signing lib for SponsoredOFTQuoteSignedParams.
///         No EIP-191 or EIP-712 domain separation is applied by design so the
///         same signature can be verified on multiple chains/contracts.
library SponsoredOFTQuoteSignLib {
    using ECDSA for bytes32;

    /// @notice Compute the raw keccak256 hash of the signed params using abi.encode.
    function hash(SponsoredOFTQuoteSignedParams calldata p) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    p.srcEid,
                    p.srcPeriphery,
                    p.dstEid,
                    p.to,
                    p.amountLD,
                    p.nonce,
                    p.deadline,
                    p.maxSponsorshipAmount,
                    p.finalRecipient,
                    p.finalToken
                )
            );
    }

    /// @notice Recover the signer for the given params and signature.
    function recoverSigner(
        SponsoredOFTQuoteSignedParams calldata p,
        bytes calldata signature
    ) internal pure returns (address) {
        bytes32 digest = hash(p);
        return digest.recover(signature);
    }

    /// @notice Verify that `expectedSigner` signed `p` with `signature`.
    function verify(
        address expectedSigner,
        SponsoredOFTQuoteSignedParams calldata p,
        bytes calldata signature
    ) internal pure returns (bool) {
        return recoverSigner(p, signature) == expectedSigner;
    }
}
