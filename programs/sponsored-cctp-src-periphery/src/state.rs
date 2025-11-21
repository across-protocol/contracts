use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct State {
    pub source_domain: u32, // Immutable CCTP domain for the chain this program is deployed on (e.g. 5 for Solana).
    pub signer: Pubkey,     // The authorized signer for sponsored CCTP quotes.
    pub current_time: u64,  // Only used in testable mode, else set to 0 on mainnet.
}

#[account]
#[derive(InitSpace)]
pub struct UsedNonce {
    pub quote_deadline: u64, // Quote deadline is used to determine when it is safe to close the nonce account.
}

#[account]
#[derive(InitSpace)]
pub struct MinimumDeposit {
    pub amount: u64, // Minimum deposit amount for a given burn token, set by the admin.
    pub bump: u8,    // Seed bump for the PDA.
}
