use anchor_lang::prelude::*;

use crate::{message_transmitter_v2::accounts::MessageSent, utils::SponsoredCCTPQuote};

#[cfg(not(feature = "test"))]
#[account]
#[derive(InitSpace)]
pub struct State {
    pub source_domain: u32, // Immutable CCTP domain for the chain this program is deployed on (e.g. 5 for Solana).
    pub signer: Pubkey,     // The authorized signer for sponsored CCTP quotes.
    pub bump: u8,           // Seed bump for the state account.
}

#[cfg(feature = "test")]
#[account]
#[derive(InitSpace)]
pub struct State {
    pub source_domain: u32, // Immutable CCTP domain for the chain this program is deployed on (e.g. 5 for Solana).
    pub signer: Pubkey,     // The authorized signer for sponsored CCTP quotes.
    pub bump: u8,           // Seed bump for the state account.
    pub current_time: u64,  // Only used in testable mode.
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

impl UsedNonce {
    pub fn space() -> usize {
        Self::DISCRIMINATOR.len() + Self::INIT_SPACE
    }
}

pub trait MessageSentSpace {
    fn space(quote: &SponsoredCCTPQuote) -> usize;
}

impl MessageSentSpace for MessageSent {
    fn space(quote: &SponsoredCCTPQuote) -> usize {
        const DISCRIMINATOR_SIZE: usize = 8;
        const RENT_PAYER_SIZE: usize = core::mem::size_of::<Pubkey>(); // rent_payer: Pubkey
        const CREATED_AT_SIZE: usize = core::mem::size_of::<i64>(); // created_at: i64
        const MESSAGE_LEN_SIZE: usize = 4; // message: Vec<u8>

        const MESSAGE_BODY_INDEX: usize = 148; // https://developers.circle.com/cctp/technical-guide#message-header
        const HOOK_DATA_INDEX: usize = 228; // https://developers.circle.com/cctp/technical-guide#message-body

        let encoded_hook_data_len = quote.encoded_hook_data_len();

        DISCRIMINATOR_SIZE
            + RENT_PAYER_SIZE
            + CREATED_AT_SIZE
            + MESSAGE_LEN_SIZE
            + MESSAGE_BODY_INDEX
            + HOOK_DATA_INDEX
            + encoded_hook_data_len
    }
}

#[account]
#[derive(InitSpace)]
pub struct RentClaim {
    pub amount: u64, // Amount of lamports to be refunded to the user later.
}
