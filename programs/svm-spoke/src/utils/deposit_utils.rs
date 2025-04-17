use anchor_lang::{prelude::*, solana_program::keccak};

#[derive(Accounts)]
pub struct Null {} // Define a dummy context struct so we can export this as a view function in lib.
pub fn get_unsafe_deposit_id(msg_sender: Pubkey, depositor: Pubkey, deposit_nonce: u64) -> [u8; 32] {
    let mut data = Vec::new();

    AnchorSerialize::serialize(&(msg_sender, depositor, deposit_nonce), &mut data).unwrap();

    keccak::hash(&data).to_bytes()
}

pub fn derive_delegate_seed_hash(
    state_seed: u64,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: u64,
    destination_chain_id: u64,
) -> [u8; 32] {
    let mut data = Vec::with_capacity(8 + 32 + 32 + 8 + 8 + 8);
    data.extend_from_slice(&state_seed.to_le_bytes());
    data.extend_from_slice(input_token.as_ref());
    data.extend_from_slice(output_token.as_ref());
    data.extend_from_slice(&input_amount.to_le_bytes());
    data.extend_from_slice(&output_amount.to_le_bytes());
    data.extend_from_slice(&destination_chain_id.to_le_bytes());
    keccak::hash(&data).to_bytes()
}
