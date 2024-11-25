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
    pub status: FillStatus, // Tracks the status of the fill between Unfilled, requestedSlowFill, and Filled.
    pub relayer: Pubkey,    // Address of the relayer that made the fill to control who can close this PDA.
}
