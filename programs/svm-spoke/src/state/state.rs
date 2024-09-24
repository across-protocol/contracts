use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct State {
    pub paused_deposits: bool,
    pub paused_fills: bool,
    pub owner: Pubkey,
    pub seed: u64, // Add a seed to the state to enable multiple deployments.
    pub number_of_deposits: u32,
    pub chain_id: u64,              // Across definition of chainId for Solana.
    pub current_time: u32,          // Only used in testable mode, else set to 0 on mainnet.
    pub remote_domain: u32,         // CCTP domain for Mainnet Ethereum.
    pub cross_domain_admin: Pubkey, // HubPool on Mainnet Ethereum.
    pub root_bundle_id: u32,
}
