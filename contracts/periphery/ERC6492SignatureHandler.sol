// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { IMulticall3 } from "../external/interfaces/IMulticall3.sol";

/**
 * @title ERC6492SignatureHandler
 * @notice Base contract that performs the "prepare" (deploy) step of an ERC-6492 signature without
 * being the signature verifier itself.
 * @dev Some downstream verifiers — most importantly the ERC-3009 `receiveWithAuthorization(...,bytes)`
 * overload on tokens such as USDC v2.2 — validate contract-wallet signatures via EIP-1271 but have no
 * concept of ERC-6492. A signature from a *counterfactual* (not-yet-deployed) smart-contract wallet
 * therefore fails, because there is no code at the signer's address to call `isValidSignature` on.
 *
 * ERC-6492 (https://eips.ethereum.org/EIPS/eip-6492) solves this by wrapping the real signature with
 * the factory call needed to deploy the wallet. Since we cannot change the token's verification, we
 * replicate only the *deploy* half of the flow here: if a signature carries the ERC-6492 magic
 * suffix, we run its embedded factory call to materialize the wallet, then hand the unwrapped inner
 * signature back to the caller to pass on to the real verifier (the token). Once the wallet exists,
 * the token's own EIP-1271 check against the signer succeeds.
 *
 * @dev This contract does NOT validate the signature; it only ensures the signer is deployed. The
 * embedded factory `target`/`callData` is fully attacker-controlled, so the call is routed through a
 * neutral public Multicall3 singleton rather than made directly. This guarantees the prepare call can
 * never execute with this contract as `msg.sender` and thus cannot abuse any of this contract's
 * allowances or privileges. The call is made with `requireSuccess: false`, so an already-deployed
 * wallet (whose factory call reverts on redeploy) is tolerated; correctness ultimately rests on the
 * downstream verifier.
 *
 * Inspired by Coinbase's ERC6492SignatureHandler
 * (https://github.com/base/commerce-payments/blob/main/src/collectors/ERC6492SignatureHandler.sol).
 * @custom:security-contact bugs@across.to
 */
abstract contract ERC6492SignatureHandler {
    // Magic suffix that marks a signature as ERC-6492 wrapped.
    bytes32 internal constant _ERC6492_MAGIC_VALUE = 0x6492649264926492649264926492649264926492649264926492649264926492;

    // Canonical Multicall3 singleton used to make the neutral ERC-6492 prepare/deploy call.
    IMulticall3 public immutable multicall3;

    /**
     * @notice Constructs the handler.
     * @param _multicall3 Address of the canonical Multicall3 singleton used to route prepare calls.
     */
    constructor(address _multicall3) {
        multicall3 = IMulticall3(_multicall3);
    }

    /**
     * @notice Detects an ERC-6492 wrapped signature and, if present, runs its embedded factory call
     * to deploy the (counterfactual) signer before returning the unwrapped inner signature.
     * @param signature The user-provided signature, possibly ERC-6492 wrapped.
     * @return The inner signature to forward to the real verifier. If `signature` is not ERC-6492
     * wrapped it is returned unchanged.
     */
    function _handleERC6492Signature(bytes memory signature) internal returns (bytes memory) {
        // An ERC-6492 signature is at least the 32-byte magic suffix; anything shorter passes through.
        uint256 signatureLength = signature.length;
        if (signatureLength < 32) return signature;

        // Pass through unless the trailing 32 bytes are the ERC-6492 magic value.
        bytes32 suffix;
        assembly {
            suffix := mload(add(add(signature, 32), sub(signatureLength, 32)))
        }
        if (suffix != _ERC6492_MAGIC_VALUE) return signature;

        // Strip the magic suffix and decode the wrapped (factory, factoryCalldata, innerSignature).
        bytes memory erc6492Data = new bytes(signatureLength - 32);
        for (uint256 i; i < signatureLength - 32; ++i) {
            erc6492Data[i] = signature[i];
        }
        address prepareTarget;
        bytes memory prepareData;
        (prepareTarget, prepareData, signature) = abi.decode(erc6492Data, (address, bytes, bytes));

        // Route the deploy call through the neutral Multicall3 so this contract is never the sender of
        // attacker-controlled calldata. Failure is tolerated (e.g. the wallet is already deployed);
        // the downstream verifier is the source of truth on signature validity.
        IMulticall3.Call[] memory calls = new IMulticall3.Call[](1);
        calls[0] = IMulticall3.Call(prepareTarget, prepareData);
        multicall3.tryAggregate(false, calls);

        return signature;
    }
}
