use anchor_lang::{prelude::*, solana_program::keccak};

use crate::error::{CommonError, SvmError};

pub fn hash_non_empty_message(message: &[u8]) -> [u8; 32] {
    match message.len() {
        0 => [0u8; 32],
        _ => keccak::hash(message).to_bytes(),
    }
}

// Returns true if the message is V5-tagged (starts with V5_MAGIC_PREFIX), meaning the deposit is consumable only
// through the V5 fill entrypoints.
pub fn is_v5_message(message: &[u8]) -> bool {
    message.len() >= 32 && message[..32] == crate::constants::V5_MAGIC_PREFIX
}

/// Legacy fills support token delivery only. V5 witnesses belong to the V5 adapter entrypoint.
pub fn validate_legacy_fill_message(message: &[u8]) -> Result<()> {
    require!(!is_v5_message(message), CommonError::V5FillOnly);
    require!(message.is_empty(), SvmError::LegacyFillMessageUnsupported);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_messages_and_v5_witnesses_have_distinct_errors() {
        assert!(validate_legacy_fill_message(&[]).is_ok());
        for message in [vec![1], vec![0; 64]] {
            assert!(validate_legacy_fill_message(&message)
                .unwrap_err()
                .to_string()
                .contains("LegacyFillMessageUnsupported"));
        }
        for length in [32, 64, 65] {
            let mut witness = crate::constants::V5_MAGIC_PREFIX.to_vec();
            witness.resize(length, 0);
            assert!(validate_legacy_fill_message(&witness)
                .unwrap_err()
                .to_string()
                .contains("V5FillOnly"));
        }
    }
}
