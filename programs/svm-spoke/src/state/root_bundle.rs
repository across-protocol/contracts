use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct RootBundle {
    pub relayer_refund_root: [u8; 32],
    pub slow_relay_root: [u8; 32],
    #[max_len(1)]
    pub claimed_bitmap: Vec<u8>, // Dynamic sized vec to store claimed status of each relayer refund root leaf.
}