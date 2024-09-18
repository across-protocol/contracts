use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace, PartialEq)]
pub enum FillStatus {
    Unfilled,
    RequestedSlowFill,
    Filled,
}

#[account]
#[derive(InitSpace)]
pub struct FillStatusAccount {
    pub status: FillStatus,
    pub relayer: Pubkey,
}
