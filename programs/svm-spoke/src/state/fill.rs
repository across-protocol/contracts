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
    pub relayer: Pubkey,    // Rent recipient for closing this PDA; legacy fills store the submitting relayer.
    pub fill_deadline: u32, // Stores the fill deadline to control when this PDA can be safely closed.
}
