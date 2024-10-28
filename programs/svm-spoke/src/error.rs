use anchor_lang::prelude::*;

#[error_code]
pub enum CalldataError {
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
    #[msg("Invalid solidity uint128 argument")]
    InvalidUint128,
    #[msg("Unsupported solidity selector")]
    UnsupportedSelector,
}

#[error_code]
//TODO: try make these match with the EVM codes. also, we can split them into different error types.
// TODO: EVM compatable errors should be under the same enum. SVM specific errors should be in separate enum
pub enum CustomError {
    #[msg("Only the owner can call this function!")]
    NotOwner,
    #[msg("The route is not enabled!")]
    DisabledRoute,
    #[msg("The fill deadline has passed!")]
    ExpiredFillDeadline,
    #[msg("Caller is not the exclusive relayer and exclusivity deadline has not passed!")]
    NotExclusiveRelayer,
    #[msg("The Deposit is still within the exclusivity window!")]
    NoSlowFillsInExclusivityWindow,
    #[msg("Invalid route PDA!")]
    InvalidRoutePDA,
    #[msg("The relay has already been filled!")]
    RelayFilled,
    #[msg("Invalid relay hash!")]
    InvalidRelayHash,
    #[msg("The fill deadline has not passed!")]
    FillDeadlineNotPassed,
    #[msg("Slow fill requires status of Unfilled!")]
    InvalidSlowFillRequest,
    #[msg("The fill status is not filled!")]
    NotFilled,
    #[msg("The caller is not the relayer!")]
    NotRelayer,
    #[msg("Cannot set time if not in test mode!")]
    CannotSetCurrentTime,
    #[msg("Invalid remote domain!")]
    InvalidRemoteDomain,
    #[msg("Invalid remote sender!")]
    InvalidRemoteSender,
    #[msg("Invalid Merkle proof!")]
    InvalidMerkleProof,
    #[msg("Fills are currently paused!")]
    FillsArePaused,
    #[msg("Invalid chain id!")]
    InvalidChainId,
    #[msg("Invalid mint!")]
    InvalidMint,
    #[msg("Leaf already claimed!")]
    ClaimedMerkleLeaf,
    #[msg("Invalid Merkle leaf!")]
    InvalidMerkleLeaf,
    #[msg("Exceeded pending bridge amount to HubPool!")]
    ExceededPendingBridgeAmount,
    #[msg("Deposits are currently paused!")]
    DepositsArePaused,
    #[msg("Invalid quote timestamp!")]
    InvalidQuoteTimestamp,
    #[msg("Ivalid fill deadline!")]
    InvalidFillDeadline,
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
    #[msg("Seed must be 0 in production!")]
    InvalidProductionSeed,
}
