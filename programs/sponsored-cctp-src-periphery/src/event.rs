use anchor_lang::prelude::*;

#[event]
pub struct CCTPQuoteDeposited {
    pub depositor: Pubkey,
    pub burn_token: Pubkey,
    pub amount: u64,
    pub destination_domain: u32,
    pub mint_recipient: Pubkey,
    pub final_recipient: Pubkey,
    pub final_token: Pubkey,
    pub destination_caller: Pubkey,
    pub nonce: [u8; 32],
}
