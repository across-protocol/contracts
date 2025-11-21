use anchor_lang::prelude::*;

// Common Errors with EVM SponsoredCCTPSrcPeriphery.
#[error_code]
pub enum CommonError {
    #[msg("Invalid quote signature")]
    InvalidSignature,
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
    #[msg("Invalid burn_token key")]
    InvalidBurnToken,
    #[msg("Amount must be greater than 0")]
    AmountNotPositive,
    #[msg("The quote deadline has not passed!")]
    QuoteDeadlineNotPassed,
    #[msg("New signer unchanged")]
    SignerUnchanged,
    #[msg("Deposit amount below minimum")]
    DepositAmountBelowMinimum,
}
