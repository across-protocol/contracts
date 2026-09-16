use anchor_lang::{
    prelude::*,
    solana_program::{keccak, secp256k1_recover::secp256k1_recover},
};

use crate::error::V5Error;

use super::codec::{AcrossDepositInput, AcrossDepositJitParams, V5_SIGNATURE_LEN};

/// EVM-aligned JIT signature-domain revision, independent of the Across V5 protocol and SVM wire-schema versions.
pub const V5_PARAM_MODIFICATION_NAME: &[u8] = b"ACXV.AcrossDepositDelegateAdapter.V1";
pub(super) const V5_PARAM_MODIFICATION_NAME_HASH: [u8; 32] = [
    0x17, 0x5b, 0xcc, 0x73, 0x21, 0x1b, 0xd5, 0x12, 0xc1, 0x2e, 0xfd, 0xaa, 0xe2, 0xb1, 0x16, 0x2e, 0xc6, 0x59, 0xfc,
    0x84, 0x23, 0x0d, 0xe0, 0xa1, 0xe2, 0x8f, 0x01, 0xef, 0x2a, 0x71, 0x82, 0x33,
];
const SECP256K1_HALF_ORDER: [u8; 32] = [
    0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x5d, 0x57, 0x6e,
    0x73, 0x57, 0xa4, 0x50, 0x1d, 0xdf, 0xe9, 0x2f, 0x46, 0x68, 0x1b, 0x20, 0xa0,
];

fn u64_to_evm_uint(value: u64) -> [u8; 32] {
    let mut word = [0u8; 32];
    word[24..].copy_from_slice(&value.to_be_bytes());
    word
}

/// `syntheticNonce = keccak256(submitter || pathId || uint256(depositNonce))` then
/// `depositId = keccak256(executorProgramId || depositor || syntheticNonce)`.
pub fn derive_v5_deposit_id(
    executor_program_id: &Pubkey,
    submitter: &Pubkey,
    path_id: &[u8; 32],
    depositor: &Pubkey,
    deposit_nonce: u64,
) -> [u8; 32] {
    let nonce = u64_to_evm_uint(deposit_nonce);
    let synthetic_nonce = keccak::hashv(&[submitter.as_ref(), path_id, &nonce]).to_bytes();
    keccak::hashv(&[executor_program_id.as_ref(), depositor.as_ref(), &synthetic_nonce]).to_bytes()
}

pub fn v5_param_modification_domain(gateway_program_id: &Pubkey) -> [u8; 32] {
    // EVM `abi.encode(bytes32,address)` is two 32-byte words. The SVM Gateway identity is already one word.
    keccak::hashv(&[&V5_PARAM_MODIFICATION_NAME_HASH, gateway_program_id.as_ref()]).to_bytes()
}

/// EVM-compatible packed digest over fixed 32-byte words. `new_output_amount` is already a uint256 big-endian word.
pub fn v5_param_modification_digest(
    gateway_program_id: &Pubkey,
    path_id: &[u8; 32],
    deposit_nonce: u64,
    new_output_amount: &[u8; 32],
    new_exclusive_relayer: &Pubkey,
) -> [u8; 32] {
    let domain = v5_param_modification_domain(gateway_program_id);
    let nonce = u64_to_evm_uint(deposit_nonce);
    keccak::hashv(&[
        &domain,
        path_id,
        &nonce,
        new_output_amount,
        new_exclusive_relayer.as_ref(),
    ])
    .to_bytes()
}

/// Recover the 20-byte EVM authority from `r || s || v`. Only EVM-canonical v=27/28 and low-s signatures pass.
pub fn recover_v5_authority(digest: &[u8; 32], signature: &[u8; V5_SIGNATURE_LEN]) -> Result<[u8; 20]> {
    let recovery_id = match signature[64] {
        27 | 28 => signature[64] - 27,
        _ => return err!(V5Error::InvalidParamModificationSignature),
    };
    require!(signature[32..64] <= SECP256K1_HALF_ORDER[..], V5Error::InvalidParamModificationSignature);
    let public_key = secp256k1_recover(digest, recovery_id, &signature[..64])
        .map_err(|_| error!(V5Error::InvalidParamModificationSignature))?;
    let hashed = keccak::hash(public_key.to_bytes().as_ref()).to_bytes();
    Ok(hashed[12..].try_into().unwrap())
}

pub fn verify_v5_authority(
    expected_authority: &[u8; 20],
    digest: &[u8; 32],
    signature: &[u8; V5_SIGNATURE_LEN],
) -> Result<()> {
    require!(
        recover_v5_authority(digest, signature)? == *expected_authority,
        V5Error::InvalidParamModificationSignature
    );
    Ok(())
}

/// Verify and apply only the committed JIT permissions. Output-amount changes are improvement-only. When an authority
/// is configured, all proposed values remain signature-bound even if unpermitted; otherwise the permitted changes are
/// permissionless, matching the EVM adapter.
pub fn resolve_v5_deposit_modifications(
    input: &AcrossDepositInput,
    jit: &AcrossDepositJitParams,
    gateway_program_id: &Pubkey,
    path_id: &[u8; 32],
) -> Result<([u8; 32], Pubkey)> {
    let deposit = &input.deposit_params;
    if input.modification_rules.authority != [0u8; 20] {
        let digest = v5_param_modification_digest(
            gateway_program_id,
            path_id,
            deposit.deposit_nonce,
            &jit.new_output_amount,
            &jit.new_exclusive_relayer,
        );
        verify_v5_authority(&input.modification_rules.authority, &digest, &jit.signature)?;
    }

    let output_amount = if input.modification_rules.allow_output_amount {
        require!(jit.new_output_amount >= deposit.output_amount, V5Error::ParamModificationNotAnImprovement);
        jit.new_output_amount
    } else {
        deposit.output_amount
    };
    let exclusive_relayer = if input.modification_rules.allow_exclusive_relayer {
        jit.new_exclusive_relayer
    } else {
        deposit.exclusive_relayer
    };
    Ok((output_amount, exclusive_relayer))
}
