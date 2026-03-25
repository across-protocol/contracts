use anchor_lang::{prelude::*, solana_program::keccak};

pub fn derive_seed_hash<T: AnchorSerialize>(seed: &T) -> [u8; 32] {
    let mut data = Vec::new();
    AnchorSerialize::serialize(seed, &mut data).unwrap();
    keccak::hash(&data).to_bytes()
}

#[derive(AnchorSerialize)]
pub struct DepositSeedData<'a> {
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: [u8; 32],
    pub destination_chain_id: u64,
    pub exclusive_relayer: Pubkey,
    pub quote_timestamp: u32,
    pub fill_deadline: u32,
    pub exclusivity_parameter: u32,
    pub message: &'a Vec<u8>,
}

#[derive(AnchorSerialize)]
pub struct DepositNowSeedData<'a> {
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: [u8; 32],
    pub destination_chain_id: u64,
    pub exclusive_relayer: Pubkey,
    pub fill_deadline_offset: u32,
    pub exclusivity_period: u32,
    pub message: &'a Vec<u8>,
}

#[derive(AnchorSerialize)]
pub struct FillSeedData {
    pub relay_hash: [u8; 32],
    pub repayment_chain_id: u64,
    pub repayment_address: Pubkey,
}
