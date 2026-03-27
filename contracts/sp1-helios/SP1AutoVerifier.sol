// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ISP1Verifier } from "@sp1-contracts/src/ISP1Verifier.sol";

/// @title SP1 Auto Verifier
/// @notice A no-op verifier that accepts any proof. Useful for testing SP1Helios without real proofs.
contract SP1AutoVerifier is ISP1Verifier {
    // pure is intentionally stricter than the interface's view; Solidity allows this and it's correct for a no-op.
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}
