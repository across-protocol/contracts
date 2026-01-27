// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { ECDSA } from "@openzeppelin/contracts-v4/utils/cryptography/ECDSA.sol";
import { SignedQuoteParams } from "./Structs.sol";

/// @notice Lib to check the signature for `SignedQuoteParams`.
/// The signature is checked against a keccak hash of abi-encoded fields of `SignedQuoteParams`
library QuoteSignLib {
    using ECDSA for bytes32;

    /// @notice Compute the keccak of all `SignedQuoteParams` fields
    function hash(SignedQuoteParams calldata p) internal pure returns (bytes32) {
        // We split the hashing into two parts to avoid "stack too deep" error
        bytes32 hash1 = keccak256(
            abi.encode(
                p.srcEid,
                p.dstEid,
                p.destinationHandler,
                p.amountLD,
                p.nonce,
                p.deadline,
                p.maxBpsToSponsor,
                p.finalRecipient
            )
        );

        bytes32 hash2 = keccak256(
            abi.encode(
                p.finalToken,
                p.destinationDex,
                p.lzReceiveGasLimit,
                p.lzComposeGasLimit,
                p.maxOftFeeBps,
                p.accountCreationMode,
                p.executionMode,
                keccak256(p.actionData) // Hash the actionData to keep signature size reasonable
            )
        );

        return keccak256(abi.encode(hash1, hash2));
    }

    /// @notice Recover the signer for the given params and signature.
    function recoverSigner(SignedQuoteParams calldata p, bytes calldata signature) internal pure returns (address) {
        bytes32 digest = hash(p);
        return digest.recover(signature);
    }

    /// @notice Verify that `expectedSigner` signed `p` with `signature`.
    function isSignatureValid(
        address expectedSigner,
        SignedQuoteParams calldata p,
        bytes calldata signature
    ) internal pure returns (bool) {
        return recoverSigner(p, signature) == expectedSigner;
    }
}
