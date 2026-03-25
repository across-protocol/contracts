use anchor_lang::{prelude::*, solana_program::keccak};

#[derive(Accounts)]
pub struct Null {} // Define a dummy context struct so we can export this as a view function in lib.
pub fn get_unsafe_deposit_id(msg_sender: Pubkey, depositor: Pubkey, deposit_nonce: u64) -> [u8; 32] {
    let mut data = Vec::new();

    AnchorSerialize::serialize(&(msg_sender, depositor, deposit_nonce), &mut data).unwrap();

    keccak::hash(&data).to_bytes()
}
