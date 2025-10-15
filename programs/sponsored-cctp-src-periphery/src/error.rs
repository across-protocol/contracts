use anchor_lang::prelude::*;

// Common Errors with EVM SponsoredCCTPPeriphery.
#[error_code]
pub enum CommonError {
    #[msg("Invalid quote deadline")]
    InvalidDeadline,
    #[msg("Invalid source domain")]
    InvalidSourceDomain,
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
}

// EVM decoding errors.
#[error_code]
pub enum DataDecodingError {
    #[msg("Cannot decode to u32")]
    CannotDecodeToU32,
    #[msg("Cannot decode to u64")]
    CannotDecodeToU64,
}
