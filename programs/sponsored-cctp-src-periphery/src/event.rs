use anchor_lang::prelude::*;

#[event]
pub struct QuoteSignerSet {
    pub old_quote_signer: Pubkey,
    pub new_quote_signer: Pubkey,
}

#[event]
pub struct WithdrawnRentFund {
    pub amount: u64,
    pub recipient: Pubkey,
}

#[event]
pub struct CCTPQuoteDeposited {
    pub depositor: Pubkey,
    pub burn_token: Pubkey,
    pub amount: u64,
    pub destination_domain: u32,
    pub mint_recipient: Pubkey,
    pub final_recipient: Pubkey,
    pub final_token: Pubkey,
    pub destination_caller: Pubkey,
    pub nonce: Pubkey, // Nonce is bytes32 random value, but it is more readable in logs expressed as Pubkey.
}

#[event]
pub struct ReclaimedEventAccount {
    pub message_sent_event_data: Pubkey,
}

#[event]
pub struct ReclaimedUsedNonceAccount {
    pub nonce: Pubkey, // Nonce is bytes32 random value, but it is more readable in logs expressed as Pubkey.
    pub used_nonce: Pubkey, // PDA derived from above nonce that got closed.
}
