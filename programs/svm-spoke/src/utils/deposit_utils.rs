use anchor_lang::{prelude::*, solana_program::keccak};

#[derive(Accounts)]
pub struct Null {} // Define a dummy context struct so we can export this as a view function in lib.
pub fn get_unsafe_deposit_id(msg_sender: Pubkey, depositor: Pubkey, deposit_nonce: u64) -> [u8; 32] {
    let mut data = Vec::new();

    AnchorSerialize::serialize(&(msg_sender, depositor, deposit_nonce), &mut data).unwrap();

    keccak::hash(&data).to_bytes()
}

#[derive(AnchorSerialize)]
pub struct DepositDelegateSeedData {
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: u64,
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    exclusivity_parameter: u32,
    message: Vec<u8>,
}

pub fn derive_deposit_delegate_seed_hash(
    depositor: Pubkey,
    recipient: Pubkey,
    input_token: Pubkey,
    output_token: Pubkey,
    input_amount: u64,
    output_amount: u64,
    destination_chain_id: u64,
    exclusive_relayer: Pubkey,
    exclusivity_parameter: u32,
    message: Vec<u8>,
) -> [u8; 32] {
    let data_struct = DepositDelegateSeedData {
        depositor,
        recipient,
        input_token,
        output_token,
        input_amount,
        output_amount,
        destination_chain_id,
        exclusive_relayer,
        exclusivity_parameter,
        message,
    };
    let serialized = data_struct.try_to_vec().unwrap();

    keccak::hash(&serialized).to_bytes()
}
