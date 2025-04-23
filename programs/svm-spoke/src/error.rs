use anchor_lang::prelude::*;

// Common Errors with EVM SpokePool.
#[error_code]
pub enum CommonError {
    #[msg("The route is not enabled!")]
    DisabledRoute,
    #[msg("Invalid quote timestamp!")]
    InvalidQuoteTimestamp,
    #[msg("Ivalid fill deadline!")]
    InvalidFillDeadline,
    #[msg("Caller is not the exclusive relayer and exclusivity deadline has not passed!")]
    NotExclusiveRelayer,
    #[msg("The Deposit is still within the exclusivity window!")]
    NoSlowFillsInExclusivityWindow,
    #[msg("The relay has already been filled!")]
    RelayFilled,
    #[msg("Slow fill requires status of Unfilled!")]
    InvalidSlowFillRequest,
    #[msg("The fill deadline has passed!")]
    ExpiredFillDeadline,
    #[msg("Invalid Merkle proof!")]
    InvalidMerkleProof,
    #[msg("Invalid chain id!")]
    InvalidChainId,
    #[msg("Invalid Merkle leaf!")]
    InvalidMerkleLeaf,
    #[msg("Leaf already claimed!")]
    ClaimedMerkleLeaf,
    #[msg("Deposits are currently paused!")]
    DepositsArePaused,
    #[msg("Fills are currently paused!")]
    FillsArePaused,
    #[msg("Insufficient spoke pool balance to execute leaf")]
    InsufficientSpokePoolBalanceToExecuteLeaf,
    #[msg("Invalid exclusive relayer!")]
    InvalidExclusiveRelayer,
}

// SVM specific errors.
#[error_code]
pub enum SvmError {
    #[msg("Only the owner can call this function!")]
    NotOwner,
    #[msg("Invalid relay hash!")]
    InvalidRelayHash,
    #[msg("The fill deadline has not passed!")]
    CanOnlyCloseFillStatusPdaIfFillDeadlinePassed,
    #[msg("The caller is not the relayer!")]
    NotRelayer,
    #[msg("Cannot set time if not in test mode!")]
    CannotSetCurrentTime,
    #[msg("Invalid remote domain!")]
    InvalidRemoteDomain,
    #[msg("Invalid remote sender!")]
    InvalidRemoteSender,
    #[msg("Invalid mint!")]
    InvalidMint,
    #[msg("Exceeded pending bridge amount to HubPool!")]
    ExceededPendingBridgeAmount,
    #[msg("Overflow writing to parameters account!")]
    ParamsWriteOverflow,
    #[msg("Invalid refund address!")]
    InvalidRefund,
    #[msg("Zero relayer refund claim!")]
    ZeroRefundClaim,
    #[msg("Cannot close non-zero relayer refund claim!")]
    NonZeroRefundClaim,
    #[msg("Invalid claim initializer!")]
    InvalidClaimInitializer,
    #[msg("Invalid refund token account!")]
    InvalidRefundTokenAccount,
    #[msg("Seed must be 0 in production!")]
    InvalidProductionSeed,
    #[msg("Invalid remaining accounts for ATA creation!")]
    InvalidATACreationAccounts,
}

// CCTP specific errors.
#[error_code]
pub enum CallDataError {
    #[msg("Invalid solidity selector")]
    InvalidSelector,
    #[msg("Invalid solidity argument")]
    InvalidArgument,
    #[msg("Invalid solidity bool argument")]
    InvalidBool,
    #[msg("Invalid solidity address argument")]
    InvalidAddress,
    #[msg("Invalid solidity uint32 argument")]
    InvalidUint32,
    #[msg("Invalid solidity uint64 argument")]
    InvalidUint64,
    #[msg("Unsupported solidity selector")]
    UnsupportedSelector,
}

// Across+ specific errors.
#[error_code]
pub enum AcrossPlusError {
    #[msg("Message did not deserialize")]
    MessageDidNotDeserialize,
    #[msg("Invalid handle message key length")]
    InvalidMessageKeyLength,
    #[msg("Invalid handle message read-only key length")]
    InvalidReadOnlyKeyLength,
    #[msg("Invalid message handler key")]
    InvalidMessageHandler,
    #[msg("Invalid message account key")]
    InvalidMessageAccountKey,
    #[msg("Not read-only message account key")]
    NotReadOnlyMessageAccountKey,
    #[msg("Not writable message account key")]
    NotWritableMessageAccountKey,
    #[msg("Missing value recipient key")]
    MissingValueRecipientKey,
}
