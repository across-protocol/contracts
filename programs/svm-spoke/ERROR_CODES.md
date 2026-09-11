# Spoke runtime error-code migration

This release assigns distinct runtime error ranges to `svm_spoke`. **Existing `CommonError` codes are unchanged.**
`SvmError` moves from 6000–6018 to 7000–7018, and `CallDataError` moves from 6000–6006 to 8000–8006.
The callback rejection and V5 errors are new relative to
[`master` at `75d968e4`](https://github.com/across-protocol/contracts/blob/75d968e4e86c37ef12c01277345ea8ed2f550901/programs/svm-spoke/src/error.rs),
the comparison used in the tables below. A dash means the error did not exist in that baseline.

Earlier undeployed revisions of this PR used `V5Error` 7000–7017; those codes are now 9000–9017, with the same
variant order. They also used 6019 for the new `LegacyFillMessageUnsupported`, now 7019. These earlier assignments
were pre-release values.

The tables cover every current variant in [error.rs](src/error.rs) and the removed `AcrossPlusError` variants.
Use the mapping for the program version being queried. Historical transaction errors retain the old codes;
do not relabel them using the new table. Legacy
numbers overlap across enums, so a number alone cannot identify a historical error. Runtime log names distinguish
the enums. Anchor 0.31.1's generated IDL error table remains incomplete despite the distinct runtime ranges.

Before upgrading, inspect off-chain numeric-code maps and update affected consumers; stale maps can silently
mislabel errors. See [deployment sequencing](V5_ADAPTER_SPEC.md#deployment-sequencing).

## CommonError

| Error                                       | Before release | This release |
| ------------------------------------------- | -------------- | ------------ |
| `InvalidQuoteTimestamp`                     | 6000           | 6000         |
| `InvalidFillDeadline`                       | 6001           | 6001         |
| `NotExclusiveRelayer`                       | 6002           | 6002         |
| `NoSlowFillsInExclusivityWindow`            | 6003           | 6003         |
| `RelayFilled`                               | 6004           | 6004         |
| `InvalidSlowFillRequest`                    | 6005           | 6005         |
| `ExpiredFillDeadline`                       | 6006           | 6006         |
| `InvalidMerkleProof`                        | 6007           | 6007         |
| `InvalidChainId`                            | 6008           | 6008         |
| `InvalidMerkleLeaf`                         | 6009           | 6009         |
| `ClaimedMerkleLeaf`                         | 6010           | 6010         |
| `DepositsArePaused`                         | 6011           | 6011         |
| `FillsArePaused`                            | 6012           | 6012         |
| `InsufficientSpokePoolBalanceToExecuteLeaf` | 6013           | 6013         |
| `InvalidExclusiveRelayer`                   | 6014           | 6014         |
| `InvalidOutputToken`                        | 6015           | 6015         |
| `V5FillOnly`                                | —              | 6016         |

## SvmError

| Error                                           | Before release | This release |
| ----------------------------------------------- | -------------- | ------------ |
| `NotOwner`                                      | 6000           | 7000         |
| `InvalidRelayHash`                              | 6001           | 7001         |
| `CanOnlyCloseFillStatusPdaIfFillDeadlinePassed` | 6002           | 7002         |
| `NotRelayer`                                    | 6003           | 7003         |
| `CannotSetCurrentTime`                          | 6004           | 7004         |
| `InvalidRemoteDomain`                           | 6005           | 7005         |
| `InvalidRemoteSender`                           | 6006           | 7006         |
| `InvalidMint`                                   | 6007           | 7007         |
| `ExceededPendingBridgeAmount`                   | 6008           | 7008         |
| `ParamsWriteOverflow`                           | 6009           | 7009         |
| `InvalidRefund`                                 | 6010           | 7010         |
| `ZeroRefundClaim`                               | 6011           | 7011         |
| `NonZeroRefundClaim`                            | 6012           | 7012         |
| `InvalidClaimInitializer`                       | 6013           | 7013         |
| `InvalidRefundTokenAccount`                     | 6014           | 7014         |
| `InvalidProductionSeed`                         | 6015           | 7015         |
| `InvalidATACreationAccounts`                    | 6016           | 7016         |
| `InvalidDelegatePda`                            | 6017           | 7017         |
| `InconsistentOptionalParameters`                | 6018           | 7018         |
| `LegacyFillMessageUnsupported`                  | —              | 7019         |

## CallDataError

| Error                 | Before release | This release |
| --------------------- | -------------- | ------------ |
| `InvalidSelector`     | 6000           | 8000         |
| `InvalidArgument`     | 6001           | 8001         |
| `InvalidBool`         | 6002           | 8002         |
| `InvalidAddress`      | 6003           | 8003         |
| `InvalidUint32`       | 6004           | 8004         |
| `InvalidUint64`       | 6005           | 8005         |
| `UnsupportedSelector` | 6006           | 8006         |

## V5Error

| Error                               | Before release | This release |
| ----------------------------------- | -------------- | ------------ |
| `InvalidWireFormat`                 | —              | 9000         |
| `UnsupportedVersion`                | —              | 9001         |
| `InvalidParamModificationRules`     | —              | 9002         |
| `InvalidParamModificationSignature` | —              | 9003         |
| `MissingAccount`                    | —              | 9004         |
| `InvalidDispatchAuthority`          | —              | 9005         |
| `InvalidAccountMutability`          | —              | 9006         |
| `ResolvedInputAmountBelowCommitted` | —              | 9007         |
| `InsufficientDelegateAllowance`     | —              | 9008         |
| `ParamModificationNotAnImprovement` | —              | 9009         |
| `UnsupportedMode`                   | —              | 9010         |
| `InvalidTokenAccount`               | —              | 9011         |
| `UnsupportedTokenExtension`         | —              | 9012         |
| `InvalidFillPayer`                  | —              | 9013         |
| `InvalidFillStatusAccount`          | —              | 9014         |
| `FillCommitmentMismatch`            | —              | 9015         |
| `FillOutputAmountTooLow`            | —              | 9016         |
| `InsufficientVaultBalance`          | —              | 9017         |

## Removed (AcrossPlusError)

`svm_spoke` no longer emits these errors after callback retirement. Their numeric values remain in use by
`CommonError`; those enums already overlapped before this release. Remove these names from active numeric maps
while retaining them for historical decoding with the original program version and runtime log context. For
example, a stale `6004 → InvalidMessageAccountKey` mapping would mislabel `CommonError::RelayFilled`.

| Error                          | Before release | This release |
| ------------------------------ | -------------- | ------------ |
| `MessageDidNotDeserialize`     | 6000           | removed      |
| `InvalidMessageKeyLength`      | 6001           | removed      |
| `InvalidReadOnlyKeyLength`     | 6002           | removed      |
| `InvalidMessageHandler`        | 6003           | removed      |
| `InvalidMessageAccountKey`     | 6004           | removed      |
| `NotReadOnlyMessageAccountKey` | 6005           | removed      |
| `NotWritableMessageAccountKey` | 6006           | removed      |
| `MissingValueRecipientKey`     | 6007           | removed      |
