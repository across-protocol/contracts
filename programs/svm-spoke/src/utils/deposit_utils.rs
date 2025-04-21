use anchor_lang::{prelude::*, solana_program::keccak};

#[derive(Accounts)]
pub struct Null {} // Define a dummy context struct so we can export this as a view function in lib.
pub fn get_unsafe_deposit_id(msg_sender: Pubkey, depositor: Pubkey, deposit_nonce: u64) -> [u8; 32] {
    let mut data = Vec::new();

    AnchorSerialize::serialize(&(msg_sender, depositor, deposit_nonce), &mut data).unwrap();

    keccak::hash(&data).to_bytes()
}

#[derive(AnchorSerialize)]
pub struct DepositSeedData {
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: u64,
    pub destination_chain_id: u64,
    pub exclusive_relayer: Pubkey,
    pub quote_timestamp: u32,
    pub fill_deadline: u32,
    pub exclusivity_parameter: u32,
    pub message: Vec<u8>,
}

#[derive(AnchorSerialize)]
pub struct DepositNowSeedData {
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: u64,
    pub destination_chain_id: u64,
    pub exclusive_relayer: Pubkey,
    pub fill_deadline_offset: u32,
    pub exclusivity_period: u32,
    pub message: Vec<u8>,
}

pub fn derive_deposit_seed_hash<T: AnchorSerialize>(seed: &T) -> [u8; 32] {
    let mut buf = Vec::with_capacity(128);
    seed.serialize(&mut buf).unwrap();
    keccak::hash(&buf).to_bytes()
}
