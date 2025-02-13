use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct State {
    pub paused_deposits: bool,          // Tracks if deposits are paused.
    pub paused_fills: bool,             // Tracks if fills are paused.
    pub owner: Pubkey,                  // Can execute admin methods in addition to cross_domain_admin. can be zero.
    pub seed: u64,                      // Seed used when running tests to avoid address collisions. 0 on mainnet.
    pub number_of_deposits: u32,        // Number of deposits made without unsafe_deposit. Used to find deposit ID.
    pub chain_id: u64,                  // Across definition of chainId for Solana.
    pub current_time: u32,              // Only used in testable mode, else set to 0 on mainnet.
    pub remote_domain: u32,             // CCTP domain for Mainnet Ethereum.
    pub cross_domain_admin: Pubkey,     // HubPool on Mainnet Ethereum.
    pub root_bundle_id: u32,            // Tracks the next current root bundle id.
    pub deposit_quote_time_buffer: u32, // Deposit quote times can't be set more than this amount into the past/future.
    pub fill_deadline_buffer: u32,      // Fill deadlines can't be set more than this amount into the future.
}
