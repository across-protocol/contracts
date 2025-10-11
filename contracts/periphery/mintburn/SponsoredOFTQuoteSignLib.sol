// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SponsoredOFTQuoteSignedParams } from "./SponsoredOftMintBurnStructs.sol";

/// @notice Lib to check the signature for `SponsoredOFTQuoteSignedParams`.
/// The signature is checked against a keccak hash of abi-encoded fields of `SponsoredOFTQuoteSignedParams`
library SponsoredOFTQuoteSignLib {
    using ECDSA for bytes32;

    /// @notice Compute the keccak of all `SponsoredOFTQuoteSignedParams` fields
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

    // TODO: rename this perhaps. Or make it revert
    /// @notice Verify that `expectedSigner` signed `p` with `signature`.
    function verify(
        address expectedSigner,
        SponsoredOFTQuoteSignedParams calldata p,
        bytes calldata signature
    ) internal pure returns (bool) {
        return recoverSigner(p, signature) == expectedSigner;
    }
}
