use anchor_lang::prelude::*;

// Anchor 1.x exposes one error enum per program. Common errors retain their codes;
// the formerly overlapping SVM and CCTP errors use distinct ranges in this source.
#[error_code]
pub enum SponsoredCctpError {
    #[msg("Invalid quote signature")]
    InvalidSignature,
    #[msg("Invalid quote deadline")]
    InvalidDeadline,
    #[msg("Invalid source domain")]
    InvalidSourceDomain,
    // SVM specific errors (7000+).
    #[msg("Only the upgrade authority can call this instruction")]
    NotUpgradeAuthority = 1000,
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
    #[msg("Missing rent claim account")]
    MissingRentClaimAccount,
    #[msg("Rent claim amount overflow")]
    RentClaimOverflow,
    #[msg("Invalid recipient key")]
    InvalidRecipientKey,
    // CCTP BurnMessageV2 specific errors (8000+).
    #[msg("Malformed V2 burn message")]
    MalformedMessage = 2000,
    #[msg("Invalid message version")]
    InvalidMessageVersion,
    #[msg("Invalid message body version")]
    InvalidMessageBodyVersion,
}

pub use SponsoredCctpError as CommonError;
pub use SponsoredCctpError as SvmError;
pub use SponsoredCctpError as CctpBurnMessageV2Error;
