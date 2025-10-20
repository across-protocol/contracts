use anchor_lang::prelude::*;

#[event]
pub struct SignerSet {
    pub old_signer: Pubkey,
    pub new_signer: Pubkey,
}

#[event]
pub struct WithdrawnRentFund {
    pub amount: u64,
    pub recipient: Pubkey,
}

#[event]
pub struct SponsoredDepositForBurn {
    pub quote_nonce: Vec<u8>, // Nonce is bytes32 random value, but it is more readable in logs expressed as encoded data blob.
    pub origin_sender: Pubkey,
    pub final_recipient: Pubkey,
    pub quote_deadline: i64,
    pub max_bps_to_sponsor: u64,
    pub max_user_slippage_bps: u64,
    pub final_token: Pubkey,
    pub signature: Vec<u8>, // This is fixed length, but using Vec so it is shown as encoded data blob in explorers.
}

#[event]
pub struct CreatedEventAccount {
    pub message_sent_event_data: Pubkey,
}

#[event]
pub struct ReclaimedEventAccount {
    pub message_sent_event_data: Pubkey,
}

#[event]
pub struct ReclaimedUsedNonceAccount {
    pub nonce: Vec<u8>, // Nonce is bytes32 random value, but it is more readable in logs expressed as encoded data blob.
    pub used_nonce: Pubkey, // PDA derived from above nonce that got closed.
}
