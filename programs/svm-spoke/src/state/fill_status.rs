use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace, PartialEq)]
pub enum FillStatus {
    Unfilled,
    // Historical slot 1 retained for deserialization and rent cleanup. Never remove or reorder.
    RequestedSlowFill,
    Filled,
}

#[account]
#[derive(InitSpace)]
pub struct FillStatusAccount {
    pub status: FillStatus,     // Tracks fill completion to prevent replay.
    pub rent_recipient: Pubkey, // V5 payer PDA, legacy relayer, or slow-fill requester receiving reclaimed rent.
    pub fill_deadline: u32,     // Stores the fill deadline to control when this PDA can be safely closed.
}
