use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct State {
    pub source_domain: u32, // Immutable CCTP domain for the chain this program is deployed on (e.g. 5 for Solana).
    pub signer: Pubkey,     // The authorized signer for sponsored CCTP quotes.
    pub current_time: i64,  // Only used in testable mode, else set to 0 on mainnet.
}

#[account]
#[derive(InitSpace)]
pub struct UsedNonce {
    pub quote_deadline: i64, // Quote deadline is used to determine when it is safe to close the nonce account.
}
