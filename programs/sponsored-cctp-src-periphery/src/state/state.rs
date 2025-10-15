use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct State {
    pub seed: u64,            // Seed used when running tests to avoid address collisions. 0 on mainnet.
    pub quote_signer: Pubkey, // The authorized signer for sponsored CCTP quotes.
    pub current_time: u32,    // Only used in testable mode, else set to 0 on mainnet.
}
