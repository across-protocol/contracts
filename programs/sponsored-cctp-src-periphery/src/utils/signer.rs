use anchor_lang::{
    prelude::*,
    solana_program::{keccak, secp256k1_recover::secp256k1_recover},
};
use libsecp256k1::Signature as EVMSignature;

use crate::{error::CommonError, utils::SponsoredCCTPQuote};

pub const QUOTE_SIGNATURE_LENGTH: usize = 65;

/// Utility function to recover the quote signer EVM address.
/// Based on CCTP's `recover_attester` function in
/// https://github.com/circlefin/solana-cctp-contracts/blob/03f7dec786eb9affa68688954f62917edeed2e35/programs/v2/message-transmitter-v2/src/state.rs
fn recover_signer(quote_hash: &[u8; 32], quote_signature: &[u8; QUOTE_SIGNATURE_LENGTH]) -> Result<Pubkey> {
    // No need to validate the length of inputs as they are fixed-size arrays compared to CCTP's implementation.

    // Extract and validate recovery id from the signature.
    let ethereum_recovery_id = quote_signature[QUOTE_SIGNATURE_LENGTH - 1];
    if !(27..=30).contains(&ethereum_recovery_id) {
        return err!(CommonError::InvalidSignature);
    }
    let recovery_id = ethereum_recovery_id - 27;

    // Reject high-s value signatures to prevent malleability.
    let signature = EVMSignature::parse_standard_slice(&quote_signature[0..QUOTE_SIGNATURE_LENGTH - 1])
        .map_err(|_| CommonError::InvalidSignature)?;
    if signature.s.is_high() {
        return err!(CommonError::InvalidSignature);
    }

    // Recover quote signer's public key.
    let public_key = secp256k1_recover(quote_hash, recovery_id, &quote_signature[0..QUOTE_SIGNATURE_LENGTH - 1])
        .map_err(|_| CommonError::InvalidSignature)?;

    // Hash public key and return last 20 bytes (EVM address) as Pubkey.
    let mut address = keccak::hash(public_key.to_bytes().as_slice()).to_bytes();
    address[0..12].iter_mut().for_each(|x| {
        *x = 0;
    });

    Ok(Pubkey::new_from_array(address))
}

pub fn validate_signature(
    expected_signer: Pubkey,
    quote: &SponsoredCCTPQuote,
    quote_signature: &[u8; QUOTE_SIGNATURE_LENGTH],
) -> Result<()> {
    let recovered_signer = recover_signer(&quote.evm_typed_hash(), quote_signature)?;
    if recovered_signer != expected_signer {
        return err!(CommonError::InvalidSignature);
    }

    Ok(())
}
