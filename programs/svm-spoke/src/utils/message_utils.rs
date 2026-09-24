use anchor_lang::solana_program::keccak;

pub fn hash_non_empty_message(message: &[u8]) -> [u8; 32] {
    match message.len() {
        0 => [0u8; 32],
        _ => keccak::hash(message).to_bytes(),
    }
}
