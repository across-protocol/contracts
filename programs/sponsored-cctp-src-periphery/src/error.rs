use anchor_lang::prelude::*;

// Common Errors with EVM SponsoredCCTPPeriphery.
#[error_code]
pub enum CommonError {
    #[msg("Invalid quote deadline")]
    InvalidDeadline,
    #[msg("Invalid source domain")]
    InvalidSourceDomain,
    #[msg("Quote signer is not set")]
    QuoteSignerNotSet,
}

// SVM specific errors.
#[error_code]
pub enum SvmError {
    #[msg("Only the upgrade authority can call this instruction")]
    NotUpgradeAuthority,
    #[msg("Invalid program data account")]
    InvalidProgramData,
    #[msg("Cannot set time if not in test mode")]
    CannotSetCurrentTime,
    #[msg("Seed must be 0 in production")]
    InvalidProductionSeed,
    #[msg("Invalid mint key")]
    InvalidMint,
    #[msg("Amount must be greater than 0")]
    AmountNotPositive,
    #[msg("The quote deadline has not passed!")]
    QuoteDeadlineNotPassed,
}

// EVM decoding errors.
#[error_code]
pub enum DataDecodingError {
    #[msg("Cannot decode to u32")]
    CannotDecodeToU32,
    #[msg("Cannot decode to u64")]
    CannotDecodeToU64,
}

// Quote signature errors.
#[error_code]
pub enum QuoteSignatureError {
    #[msg("Invalid quote signature")]
    InvalidSignature,
    #[msg("Invalid signature length")]
    InvalidSignatureLength,
    #[msg("Invalid signature recovery id")]
    InvalidSignatureRecoveryId,
    #[msg("Invalid signature s value")]
    InvalidSignatureSValue,
    #[msg("Invalid quote hash")]
    InvalidQuoteHash,
    #[msg("Invalid quote data length")]
    InvalidQuoteDataLength,
}
