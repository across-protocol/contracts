use anchor_lang::{prelude::*, solana_program::keccak};

#[derive(AnchorSerialize)]
pub struct FillDelegateSeedData {
    relay_hash: [u8; 32],
    repayment_chain_id: u64,
    repayment_address: Pubkey,
}

pub fn derive_fill_delegate_seed_hash(
    relay_hash: [u8; 32],
    repayment_chain_id: u64,
    repayment_address: Pubkey,
) -> [u8; 32] {
    let data_struct = FillDelegateSeedData { relay_hash, repayment_chain_id, repayment_address };
    let serialized = data_struct.try_to_vec().unwrap();
    // Log the raw bytes being hashed
    msg!("derive_fill_delegate_seed_hash: relay_hash: {:?}", relay_hash);
    msg!("derive_fill_delegate_seed_hash: repayment_chain_id: {:?}", repayment_chain_id);
    msg!("derive_fill_delegate_seed_hash: repayment_address: {:?}", repayment_address);

    // Compute keccak256
    let hash_bytes = keccak::hash(&serialized).to_bytes();
    // Log the resulting hash

    hash_bytes
}
