# Spoke runtime error-code migration

This release assigns distinct runtime error ranges to `svm_spoke`. **Existing `CommonError` codes are unchanged.**
`SvmError` moves from 6000–6018 to 7000–7016 after unused variants are removed; `CallDataError` moves from
6000–6006 to 9000–9006.
The compatibility baseline is the deployed release
[`v5.0.12-beta.1` (`d8da3000`)](https://github.com/across-protocol/contracts/blob/d8da3000f1aba2593e712a9942a3249bf8e8205b/programs/svm-spoke/src/error.rs),
not intermediate PRs in this undeployed stack. V5 errors are new relative to that baseline. A dash means the
error did not exist in that deployed release.

Earlier undeployed revisions used different SVM/V5 assignments and introduced `V5FillOnly` and
`LegacyFillMessageUnsupported`. Both unused callback-rejection errors are now removed; neither existed in the
deployed baseline, so they have no deployed assignments to preserve.

The tables cover every declared variant in [error.rs](src/error.rs) and every removed deployed variant.
Enum membership does not imply reachability: the old `CommonError` slow-fill slots remain reserved as noted below.
Use the mapping for the program version being queried. Historical transaction errors retain the old codes;
do not relabel them using the new table. Legacy
numbers overlap across enums, so a number alone cannot identify a historical error. Runtime log names distinguish
the enums. Anchor 0.31.1's generated IDL error table remains incomplete and does not reflect the explicit runtime
offsets; use the runtime mappings below.

Before upgrading, inspect off-chain numeric-code maps and update affected consumers; stale maps can silently
mislabel errors. See [deployment sequencing](V5_ADAPTER_SPEC.md#deployment-sequencing).

## CommonError

| Error                                       | Before release | This release |
| ------------------------------------------- | -------------- | ------------ |
| `InvalidQuoteTimestamp`                     | 6000           | 6000         |
| `InvalidFillDeadline`                       | 6001           | 6001         |
| `NotExclusiveRelayer`                       | 6002           | 6002         |
| `RetiredNoSlowFillsInExclusivityWindow`     | 6003           | 6003         |
| `RelayFilled`                               | 6004           | 6004         |
| `RetiredInvalidSlowFillRequest`             | 6005           | 6005         |
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

The two `Retired` placeholders were named `NoSlowFillsInExclusivityWindow` (6003) and `InvalidSlowFillRequest`
(6005) in the deployed release. Their numeric codes and messages are unchanged; the prefix explicitly marks
the Rust symbols, and generated names wherever exposed, as retired. Historical transaction logs keep the old names.
These slots must never be emitted, removed, or reused. Keeping them in place preserves every later live
`CommonError` assignment.

## SvmError

| Error                                           | Before release | This release |
| ----------------------------------------------- | -------------- | ------------ |
| `NotOwner`                                      | 6000           | 7000         |
| `InvalidRelayHash`                              | 6001           | removed      |
| `CanOnlyCloseFillStatusPdaIfFillDeadlinePassed` | 6002           | 7001         |
| `NotRelayer`                                    | 6003           | 7002         |
| `CannotSetCurrentTime`                          | 6004           | 7003         |
| `InvalidRemoteDomain`                           | 6005           | 7004         |
| `InvalidRemoteSender`                           | 6006           | 7005         |
| `InvalidMint`                                   | 6007           | 7006         |
| `ExceededPendingBridgeAmount`                   | 6008           | removed      |
| `NonZeroAmountToReturn`                         | —              | 7007         |
| `ParamsWriteOverflow`                           | 6009           | 7008         |
| `InvalidRefund`                                 | 6010           | 7009         |
| `ZeroRefundClaim`                               | 6011           | 7010         |
| `NonZeroRefundClaim`                            | 6012           | 7011         |
| `InvalidClaimInitializer`                       | 6013           | 7012         |
| `InvalidRefundTokenAccount`                     | 6014           | 7013         |
| `InvalidProductionSeed`                         | 6015           | 7014         |
| `InvalidATACreationAccounts`                    | 6016           | 7015         |
| `InvalidDelegatePda`                            | 6017           | 7016         |
| `InconsistentOptionalParameters`                | 6018           | removed      |

The CCTP V2 migration replaces `ExceededPendingBridgeAmount` with `NonZeroAmountToReturn`, which rejects
relayer refund leaves that return tokens to the HubPool. V4 entrypoint retirement removes `InvalidRelayHash`
and `InconsistentOptionalParameters`; neither has a remaining construction site. The final 7000–7016 mapping
includes these removals. Intermediate stack assignments were never deployed and are not compatibility constraints.

## V5Error

| Error                               | Before release | This release |
| ----------------------------------- | -------------- | ------------ |
| `InvalidWireFormat`                 | —              | 8000         |
| `InvalidParamModificationSignature` | —              | 8001         |
| `MissingAccount`                    | —              | 8002         |
| `InvalidDispatchAuthority`          | —              | 8003         |
| `InvalidAccountMutability`          | —              | 8004         |
| `ResolvedInputAmountBelowCommitted` | —              | 8005         |
| `ParamModificationNotAnImprovement` | —              | 8006         |
| `InvalidAmountBips`                 | —              | 8007         |
| `UnsupportedMode`                   | —              | 8008         |
| `InvalidTokenAccount`               | —              | 8009         |
| `UnsupportedTokenExtension`         | —              | 8010         |
| `InvalidFillPayer`                  | —              | 8011         |
| `InvalidFillStatusAccount`          | —              | 8012         |
| `FillCommitmentMismatch`            | —              | 8013         |
| `FillOutputAmountTooLow`            | —              | 8014         |
| `InsufficientVaultBalance`          | —              | 8015         |

## CallDataError

| Error                 | Before release | This release |
| --------------------- | -------------- | ------------ |
| `InvalidSelector`     | 6000           | 9000         |
| `InvalidArgument`     | 6001           | 9001         |
| `InvalidBool`         | 6002           | 9002         |
| `InvalidAddress`      | 6003           | 9003         |
| `InvalidUint32`       | 6004           | 9004         |
| `InvalidUint64`       | 6005           | 9005         |
| `UnsupportedSelector` | 6006           | 9006         |

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
