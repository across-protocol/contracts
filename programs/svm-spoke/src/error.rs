use anchor_lang::prelude::*;

// Common Errors with EVM SpokePool.
#[error_code]
pub enum CommonError {
    #[msg("Invalid quote timestamp!")]
    InvalidQuoteTimestamp,
    #[msg("Invalid fill deadline!")]
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
    #[msg("Invalid output token!")]
    InvalidOutputToken,
    #[msg("V5 deposits are only consumable via the V5 fill entrypoints!")]
    V5FillOnly,
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
    #[msg("Invalid delegate PDA!")]
    InvalidDelegatePda,
}

// Across V5 adapter specific errors.
#[error_code(offset = 7000)]
pub enum V5Error {
    #[msg("Malformed Across V5 wire data!")]
    InvalidWireFormat,
    #[msg("Unsupported Across V5 wire version!")]
    UnsupportedVersion,
    #[msg("Invalid Across V5 parameter modification rules!")]
    InvalidParamModificationRules,
    #[msg("Invalid Across V5 parameter modification signature!")]
    InvalidParamModificationSignature,
    #[msg("Missing required Across V5 account!")]
    MissingAccount,
    #[msg("Invalid Across V5 Gateway dispatch authority!")]
    InvalidDispatchAuthority,
    #[msg("Across V5 account must be writable!")]
    InvalidAccountMutability,
    #[msg("Resolved Across V5 input amount is below the committed floor!")]
    ResolvedInputAmountBelowCommitted,
    #[msg("Across V5 delegate allowance is insufficient!")]
    InsufficientDelegateAllowance,
    #[msg("Across V5 parameter modification is not an improvement!")]
    ParamModificationNotAnImprovement,
    #[msg("Across V5 adapter mode is not enabled!")]
    UnsupportedMode,
    #[msg("Invalid Across V5 token account!")]
    InvalidTokenAccount,
    #[msg("Unsupported Across V5 token extension!")]
    UnsupportedTokenExtension,
    #[msg("Invalid Across V5 fill payer!")]
    InvalidFillPayer,
    #[msg("Invalid Across V5 fill status account!")]
    InvalidFillStatusAccount,
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
