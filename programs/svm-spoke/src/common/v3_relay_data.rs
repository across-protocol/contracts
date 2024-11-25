use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct V3RelayData {
    pub depositor: Pubkey,
    pub recipient: Pubkey,
    pub exclusive_relayer: Pubkey,
    pub input_token: Pubkey,
    pub output_token: Pubkey,
    pub input_amount: u64,
    pub output_amount: u64,
    pub origin_chain_id: u64,
    pub deposit_id: [u8; 32],
    pub fill_deadline: u32,
    pub exclusivity_deadline: u32,
    pub message: Vec<u8>,
}
