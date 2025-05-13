use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct TransferLiability {
    pub pending_to_hub_pool: u64, // Amount of tokens pending to be transferred to the hub pool.
}
