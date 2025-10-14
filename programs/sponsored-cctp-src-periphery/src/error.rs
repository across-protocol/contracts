use anchor_lang::prelude::*;

// SVM specific errors.
#[error_code]
pub enum SvmError {
    #[msg("Cannot set time if not in test mode")]
    CannotSetCurrentTime,
    #[msg("Seed must be 0 in production")]
    InvalidProductionSeed,
    #[msg("Invalid SponsoredCCTPQuote data length")]
    InvalidQuoteDataLength,
}

// EVM decoding errors.
#[error_code]
pub enum DataDecodingError {
    #[msg("Cannot decode to u32")]
    CannotDecodeToU32,
    #[msg("Cannot decode to u64")]
    CannotDecodeToU64,
}
