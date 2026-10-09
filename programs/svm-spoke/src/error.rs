use anchor_lang::prelude::*;

// Anchor 1.1 requires one IDL error enum. Preserve the existing runtime ranges.
#[error_code(offset = 6000)]
pub enum SpokeError {
    // Common errors with EVM SpokePool (6000–6015).
    #[msg("Invalid quote timestamp!")]
    InvalidQuoteTimestamp,
    #[msg("Invalid fill deadline!")]
    InvalidFillDeadline,
    #[msg("Caller is not the exclusive relayer and exclusivity deadline has not passed!")]
    NotExclusiveRelayer,
    // Reserved deployed slot 6003. Never emit, remove, or reuse.
    #[msg("The Deposit is still within the exclusivity window!")]
    RetiredNoSlowFillsInExclusivityWindow,
    #[msg("The relay has already been filled!")]
    RelayFilled,
    // Reserved deployed slot 6005. Never emit, remove, or reuse.
    #[msg("Slow fill requires status of Unfilled!")]
    RetiredInvalidSlowFillRequest,
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
    // SVM specific errors (7000–7016).
    #[msg("Only the owner can call this function!")]
    NotOwner = 1000,
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
    #[msg("Relayer refund leaf must not return tokens to HubPool!")]
    NonZeroAmountToReturn,
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
    // Across V5 adapter specific errors (8000–8014).
    #[msg("Malformed Across V5 wire data!")]
    InvalidWireFormat = 2000,
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
    #[msg("Across V5 parameter modification is not an improvement!")]
    ParamModificationNotAnImprovement,
    #[msg("Across V5 input amount bips exceed the denominator!")]
    InvalidAmountBips,
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
    #[msg("Across V5 fill data does not match the committed input!")]
    FillCommitmentMismatch,
    #[msg("Across V5 fill output amount is below the committed floor!")]
    FillOutputAmountTooLow,
    // CCTP specific errors (9000–9006).
    #[msg("Invalid solidity selector")]
    InvalidSelector = 3000,
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

// Retain the existing call-site names while publishing one complete IDL error table.
pub use SpokeError as CommonError;
pub use SpokeError as SvmError;
pub use SpokeError as V5Error;
pub use SpokeError as CallDataError;
