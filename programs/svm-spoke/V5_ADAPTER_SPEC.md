# SVM SpokePool V5 adapter specification

This document freezes the compatibility surface for the Gateway-facing `svm_spoke` V5 adapter. `V5` identifies the
Across protocol generation, while `V1` identifies the first SVM wire-schema revision of a context or input variant.
Both `DepositV1` and `FillV1` are callable.

## Dispatch ABI and accounts

The frozen dispatch target is the single
`adapter_execute_across_v5(ctx_values, input, jit_data)` entrypoint, whose Anchor discriminator is the first eight
bytes of `sha256("global:adapter_execute_across_v5")`. Gateway program
`pVs6PJ3ofdqPyDhCXXdVW7waG6oNnwKQBKtuM6Mi6JP` serializes:

```text
discriminator[8]
|| step_id[32] || path_id[32] || submitter[32]
|| input_len:u32_le || input
|| jit_len:u32_le || jit_data
```

The fixed 96-byte context is `GatewayContextV1`. Input-variant versions do not version this outer dispatch ABI. A
context-layout change requires a new Gateway dispatch branch and adapter entrypoint using `GatewayContextV2`.

The common fixed Anchor accounts, in order, are:

1. `dispatch_authority`: read-only signer, PDA
   `["dispatch_authority", svm_spoke::ID]` under Gateway;
2. `state`: read-only `svm_spoke` state PDA;
3. `event_authority`: read-only `["__event_authority"]` PDA under `svm_spoke`;
4. `program`: read-only executable `svm_spoke::ID` account used by Anchor event CPI.

All token, mint, token-program, vault, delegate, fill-status, payer, ATA-program, and system-program accounts are
branch-specific remaining accounts. The implementation derives every expected key and searches by key; caller order
does not authenticate an account. Accounts that can lose lamports or whose data/token amount can change must also be
writable at the transaction level.

Deposit mode resolves the following remaining accounts by key: the committed input mint, its executable token
program, the canonical Gateway vault ATA, the pre-created canonical SpokePool vault ATA, and
`["v5_deposit_delegate"]`. Both vaults must be writable; the adapter creates no accounts and pays no rent.

## Committed input and JIT wire

`input` is strict Borsh with no trailing bytes:

```text
V5AdapterInput = enum {
  DepositV1 = 0(AcrossDepositInput),
  FillV1 = 1(V5FillInput)
}
```

The variant name encodes both the action and that action payload's wire-schema revision. Existing variants must never
be reordered. If one payload changes, append a new variant such as `DepositV2`; a safe old variant may remain accepted
temporarily while already-committed inputs drain, or be rejected immediately if its format is unsafe.

`V5FillInput` contains `recipient[32] || output_token[32] || min_output_amount:u64_le`. Unlike the EVM executor-mode
input, the SVM adapter wire intentionally omits a callback message because adapter fills do not execute recipient
callbacks.

`AcrossDepositInput` nests the canonical deposit fields under `deposit_params: AcrossDepositParams`, matching the EVM
adapter's type boundary. Borsh serializes that fixed struct inline, so the nesting adds no bytes. All Rust fields
serialize in declaration order. Integers use Borsh little-endian encoding. Pubkeys and `[u8; 32]` are raw 32-byte
values. Vectors use a `u32_le` length. `input_amount_mode` is `Literal = 0` or
`InputVaultBalance = 1 { bips: u16_le }`. The resolved SVM token amount is `u64`, while cross-VM uint256 values remain
32-byte big-endian EVM words.

Amount resolution rejects `bips` greater than 10,000; the wire decoder does not. Gateway token vaults are shared per
mint rather than isolated per execution. `InputVaultBalance` therefore resolves against shared live state, and the
continuing tape must leave no residual balance or stale approval that a later permissionless execution could consume.
Gateway does not currently enforce this net-zero settlement invariant. The adapter signs the transfer as
`v5_deposit_delegate`; the token program requires that PDA to be the vault's delegate and accepts sufficient or
maximum approvals rather than requiring equality, matching EVM `transferFrom` behavior. Any residual Gateway-vault
balance is already movable by a later committed Gateway `TRANSFER`; exact allowance would not replace that custody
invariant. The SpokePool never delegates its own vault.

Unlike the EVM `inputAmountParam`, `DepositV1` has no set-call-value flag. Native SOL must first be wrapped by the
ordinary Gateway `WRAP_SOL` command into its canonical WSOL vault; the deposit then consumes WSOL through the same
token path as any SPL input. Direct lamport deposit from this adapter is outside `DepositV1`.

Deposit JIT uses the EVM-aligned name `AcrossDepositJitParams` and is the fixed 129 bytes
`new_output_amount[32] || new_exclusive_relayer[32] || signature[65]`. A nonzero authority requires a valid signature;
when authority is zero, enabled modifications are permissionless, matching the EVM `AcrossDepositDelegateAdapter`.
These foundations decode strictly and expose `requires_jit()` but gate nothing themselves: the deposit handler must
decode `jit_data` only when the committed authority or either permission bit is nonzero, and must ignore it entirely
when all three are zero. With zero authority, enabling `allow_exclusive_relayer` lets any permissionless execution
choose an arbitrary exclusive relayer for the committed `exclusivity_parameter` window; path builders should enable
that rule shape only intentionally. Fill mode always decodes `jit_data` as `V5FillJit`. Unknown enum tags, invalid
Borsh booleans or lengths, missing required JIT, and trailing bytes in any decoded payload fail closed.

## Hashes and signatures

Canonical EVM integer encoding below means a 32-byte big-endian uint256 word:

```text
synthetic_nonce = keccak256(submitter[32] || path_id[32] || uint256(deposit_nonce:u64))
deposit_id       = keccak256(executor_program_id[32] || depositor[32] || synthetic_nonce)

name_hash = keccak256("ACXV.AcrossDepositDelegateAdapter.V1")
domain    = keccak256(name_hash || gateway_program_id[32])
digest    = keccak256(
  domain || path_id || uint256(deposit_nonce:u64) || new_output_amount[32] || new_exclusive_relayer[32]
)
```

The `.V1` suffix in the name identifies the EVM-aligned JIT signature-domain revision; it is independent of the Across
V5 protocol and SVM wire-schema versions. For `DepositV1`, Gateway is the configured executor. Deposit identity
deliberately takes `executor_program_id`, while the signature domain always takes `gateway_program_id`. Signatures are
secp256k1 `r[32] || s[32] || v[1]`, accept
only `v` 27 or 28, require low `s`, recover an uncompressed public key, and compare the last 20 bytes of its Keccak
hash with the committed authority. ERC-1271, Ed25519, EIP-2098, high-`s`, and `v` 0/1 encodings are unsupported.

Like EVM `unsafeDeposit`, source execution does not consume deposit IDs. Re-executing the same source path with
the same submitter, depositor, and nonce can transfer fresh funds under the same ID; identical relay data can only
be filled once. Builders must use a fresh source path salt or deposit nonce for each newly funded order.
Funding authorization replay protection is separate; destination roots may be reused across distinct deposits.

## PDA and token invariants

- Deposit delegate: `["v5_deposit_delegate"]` under `svm_spoke`; a preceding ordinary Gateway `APPROVE` may grant any
  allowance at least the resolved amount, including `u64::MAX`. `svm_spoke` later pulls exactly the resolved amount.
- Fill delegate: `["v5_fill_delegate"]` under `svm_spoke`; every fill requires sufficient allowance and invokes
  `transfer_checked` for the exact JIT `output_amount`, including when source and destination are the same account.
- Gateway vault authority: `["vault_authority"]` under Gateway. A Gateway vault is the canonical ATA of this authority,
  the mint, and the mint's token program.
- Fill status: the existing `["fills", relay_hash]` PDA under `svm_spoke`, preserving the standard replay namespace.
- Fill payer float: `["v5_fill_payer", submitter]` under `svm_spoke`. The data-less, system-owned PDA manually pays
  fill-status rent with `invoke_signed`; it is not a forwarded transaction signer.

For the configured Spoke program, `v5_deposit_delegate` derives
`8DWnJFMBTSDYWsUUSqna9tx9LJbU1yUfq7jTiPJDf8sX` with bump 252. Builders must use this PDA as both the approval
target and the supplied deposit delegate account.

The `v5_fill_delegate` PDA derives `D27f3mVXRL6N3bgja49UWLQu7kt57sy1aZYy7ZEwdxn1` with bump 252. Builders must use it
as both the approval target and the supplied fill delegate account for every fill, including self-transfers.
Both deposits and fills rely on the token program to validate delegate authority and allowance during
`transfer_checked`. Sufficient approval must exist when the operation executes. An unset or different delegate
fails with `OwnerMismatch` (0x4). An insufficient delegate allowance fails with `InsufficientFunds` (0x1), including
a zeroed allowance for a nonzero transfer. The mint-extension allowlist rejects `PermanentDelegate`, which could
otherwise authorize a transfer without an ordinary account approval.

Every delivery targets the canonical ATA of committed `recipient`, output mint, and token program. When that ATA is
the Gateway vault, the same transfer helper performs an SPL self-transfer, validating balance, frozen state, and
delegate authority/allowance without debiting funds or consuming allowance. Clearing the remaining allowance with
`APPROVE(..., 0)` is optional cleanup: permissionless Gateway execution already permits fresh approvals and
owner-authorized transfers, so clearing it does not protect funds left in the shared vault. A step root may be reused
across source deposits, but canonical builders must either allow at most one in-place fill before a post-fill floor
and full-balance terminal consumption, or enforce a cumulative floor covering every in-place fill recorded before
that consumption. The committed terminal outcome must be acceptable to every deposit matching the root. A fixed
minimum for one fill does not prove aggregate delivery.

The obligation covers **actual JIT output amounts for all allowed executions**, not just the sum of committed
`min_output_amount` values or the amounts in a sampled quote. Two fills can each accept output `2X` against a shared
balance of `2X`; a later floor of `2X` and full drain still deliver only half the `4X` recorded obligation. Keep
aggregate paths disabled unless their permitted relay/JIT choices and cumulative delivery are authenticated together.
Swap/action/planner paths require an equivalent proportional or aggregate postcondition on the committed final
outcome. A successful path with missing or short consumption retains its recorded fills; atomicity only rolls back a
transaction that actually fails. Failed transaction logs may contain attempted fill events; consumers must check
transaction success before accepting them.

This delivery obligation is shared with EVM. API builders and relayers must port the existing policy and applicable
conformance cases before enabling SVM routes. This test lane alone does not enable a production route or require
new aggregation support.

Fill-status expiry reclaim is permissionless and closes back to the submitter-scoped payer PDA, replenishing its
standing float. Only that submitter may withdraw the float to itself. Partial withdrawals remain subject to Solana's
runtime rent-state rules, while `u64::MAX` withdraws the live balance. This also relaxes `close_fill_pda` for existing
fill-status accounts: old clients may continue supplying the recorded relayer/requester signature, but it is no
longer required. The `FillStatusAccount.rent_recipient` field stores the payer PDA for V5 fills (historical legacy
accounts retain their recorded relayer or slow-fill requester), binding permissionless reclaim to the float that
paid the rent without an account-layout migration. V5 fills emit the existing `FilledRelay` schema and derive the relay hash
from the supplied standard `RelayData` and the configured SVM chain ID. Adapter mode uses no callback message; the
relay witness remains exactly `V5_MAGIC_PREFIX || step_id`. V5 fill status can only transition directly from an
uninitialized PDA to `Filled`.
Slow-fill request and execution entrypoints are retired for all relays. Existing legacy requested accounts and
historical event slots remain compatible as described in [historical compatibility](#historical-compatibility).

Token-2022 mint extensions fail closed. Wire version 1 permits only mint-close authority and metadata/group pointer
or data extensions. Transfer fees remain excluded until debit/delivery delta semantics are defined; transfer hooks,
permanent delegates, default-frozen accounts, and all other extensions remain disabled unless their custody and CPI
semantics are explicitly reviewed and validator-tested. This gate covers mint extensions only. Account-side guards
relevant to this path, such as source CPI guard or destination memo requirements, fail the token transfer rather than
altering accounting.

## Historical compatibility

`request_slow_fill` and `execute_slow_relay_leaf` are absent from dispatch, the public IDL, and generated clients.
Their historical selectors fail with `InstructionFallbackNotFound` (101) before account validation.
`FillStatus` retains `Unfilled = 0`, `RequestedSlowFill = 1`, and `Filled = 2`; no supported instruction creates
`RequestedSlowFill`. Account layouts and enum positions must remain stable for existing accounts.

Legacy deposit/fill entrypoints are also retired. Historical requested accounts remain readable and closable,
but cannot be fast-filled after V4 retirement. V5 fills create a new status account directly as `Filled`.
Both versions use `["fills", relay_hash]`; preserving that namespace and account layout does not migrate an
existing `RequestedSlowFill` into a V5-fillable state. The relay hash commits the fill deadline, so an expired
requested account cannot collide with an unexpired V5 relay. Expired accounts may remain for later rent cleanup;
closing them is not a prerequisite for V5 enablement. Check unexpired accounts during the deployment sequence below.

Historical `RequestedSlowFill` and `FilledRelay` events remain decodable. `FillType` retains `FastFill = 0`,
`ReplacedSlowFill = 1`, and `SlowFill = 2`; the latter two variants are historical only.
Retired slow-fill error slots remain reserved so later Common error assignments do not shift.
Indexers must check transaction success before accepting events.

`RootBundle` retains both roots and its refund-claim bitmap. The two-root admin payload still accepts nonzero
`slow_relay_root`: HubPool shares that root across chains, so it may contain other destinations' slow fills.
Rejecting it would also block the accompanying refund root. Solana stores and emits it but cannot execute it.
No account-layout or two-root admin-message migration is required. Historical instruction-parameter buffers remain
closable by their creator through `close_instruction_params` without decoding the retired parameter types.

After the recorded deadline, anyone may call `close_fill_pda`; rent goes only to the recorded recipient.
The close instruction's `signer` account and the fill-status account's `relayer` field are now named `rent_recipient`
(`rentRecipient` in generated TypeScript clients). Account order, privileges, serialized layout, and discriminators
are unchanged, so clients retaining the old IDL remain compatible. Clients adopting the new IDL must use the new
property names. Existing legacy cleanup remains compatible when the supplied wallet matches the recorded rent
recipient. Future V5 cleanup clients must supply the recorded payer PDA instead of assuming the recipient is their
wallet; reading the fill-status account provides that address. The transaction fee payer remains a separate signer.
This is part of future backend V5 integration, not a prerequisite for reclaiming legacy rent. The `NotRelayer`
error name, message, and code 7002 remain unchanged.
Closing the PDA reclaims rent, not the deposit. Unfilled expired deposits follow the dataworker-driven origin-chain
refund process; there is no destination slow-fill fallback. The reference script `scripts/svm/closeRelayerPdas.ts`
discovers live fill-status accounts by recorded rent recipient, including never-filled historical requests.
Use `--submitter` for V5 payer-PDA rent or `--relayer` for a legacy relayer/slow-fill requester. For V5, supply the
Solana submitter key, which may differ from the repayment address in `FilledRelay`.
See the [cleanup script usage](../../scripts/svm/README.md#reclaim-fill-status-rent).

## Enabled source-deposit behavior

After authenticating the live Gateway dispatch PDA, Deposit mode strictly decodes branch-specific JIT data, resolves
the input amount against the canonical Gateway vault, and pulls exactly the resolved amount into the pre-created
SpokePool vault. The token transfer enforces the static deposit delegate and sufficient allowance. The adapter applies
only signed, committed JIT modifications, derives the final 32-byte deposit ID directly from the Gateway executor
identity and live context, and emits the standard `FundsDeposited` event with
`message = V5_MAGIC_PREFIX || dst_step_id`. Any later failure in the same transaction rolls back the approval,
transfer, and event atomically.

## Enabled destination-fill behavior

Fill mode strictly decodes the JIT relay and repayment data, binds the recipient, output mint, minimum amount, and
exact `V5_MAGIC_PREFIX || step_id` witness to the committed input, and evaluates exclusivity against the
Gateway-attested submitter. It derives the canonical relay hash on-chain, creates the shared fill-status PDA from the
submitter's payer float, and emits the standard `FilledRelay` event with the original witness hash and an empty updated
message hash. Deposit and fill execution are V5-only: the adapter validates accounts and relay semantics, delivers
tokens, finalizes V5 fill status, and constructs the canonical events. The entrypoint dispatches to separate deposit
and fill modules, each owning its execution and account loading. Both loaders use `V5TokenAccounts::load` in
`instructions/v5_adapter/token.rs` to validate the mint, token program, and canonical Gateway vault before their
branch-specific recipient and delegate checks.
When the committed fill recipient is `GATEWAY_VAULT_AUTHORITY`, the fill loader reuses that validated writable account
instead of deriving, finding, and parsing the same ATA again. This reuse is confined to account loading before any
CPI; external recipient validation and the token program's self-transfer checks remain unchanged.
Every successful fill emits `FastFill` with the original recipient and output amount in its execution info.
Each execution handler performs validation, delivery, and event emission directly; fills also create and finalize
their V5 fill status in that handler.

Account resolution, dispatch authentication, and PDA derivation live in `v5/accounts.rs`. Fill-status creation and
finalization live in `v5/fill_status.rs`, while the persisted account layout lives in `state/fill_status.rs`.
The `close_fill_pda` and `withdraw_v5_fill_payer` instructions have matching files under `instructions/`; the
test-only status-creation entrypoint lives with the other test-support handlers in `utils/testable_utils.rs`.
V5 deposit identity is derived in `v5/jit.rs`. File organization does not change instruction names or persisted layouts.

All fills require a sufficient approval to `["v5_fill_delegate"]` and use the existing `transfer_from` helper for the
exact JIT output amount. External delivery debits the Gateway vault; delivery to that same vault performs a validated
self-transfer. The latter still depends on the proportional or aggregate continuing-path rule above; clearing its
unconsumed allowance is optional cleanup. Any later failure rolls back token, fill-status, and payer-float changes together.

Golden values in `fixtures/v5_adapter_v1.json` are independently re-derived from Rust, TypeScript, and Solidity to
catch byte-width, packing, and endianness drift. These are cross-language self-consistency vectors, not an invocation
of the EVM adapter. The JIT digest layout matches `AcrossDepositDelegateAdapter`, while SVM deposit identity
necessarily uses a 32-byte executor program ID instead of EVM's 20-byte caller address.

## Real Gateway conformance

`yarn test-svm-gateway` builds the actual Gateway and prefunded adapter at
[`e2b91eb0`](https://github.com/across-protocol/solana-v5/commit/e2b91eb0454136773728f941b33163346e039aa4)
and runs a separate validator alongside this checkout's test-feature SpokePool. The normal Anchor suite retains its
mock. The foreign programs have their own Anchor version; there is no cross-repository Rust dependency.

At this pin, Gateway `remaining_accounts` is only an account lookup pool. Each `ADAPTER_CALL` must name its entire
callee account list after the dispatch signer: the fixed state/event/program prefix and all branch accounts. A
committed zero-key writable injected slot identifies each fill-status/payer account; its actual key prefixes that
command's JIT payload and is independently authenticated by the SpokePool's PDA derivations. Prefunded calls similarly
inject the witness-derived credit and `PDA(["rent_refund", payer], PrefundedAdapter)` before the adapter's 32-byte
payer JIT payload. Credit closure parks rent in that system-owned PDA; a separate permissionless `claim_rent`
returns it only to the original payer. The payer account is not forwarded during settlement. Supplying an account only in
the outer pool does not forward it. Committed signer metas and duplicate dispatch metas are rejected.

This pin also includes Gateway's remainder amount form: `bips == 0xB6F2` resolves to
`max(balance - raw, 0)`, preserving `raw` as a reserve. This is separate from SpokePool's `V5InputAmountMode`.
A Gateway `TRANSFER` resolving to zero succeeds before recipient lookup, even without a recipient ATA.
The positive post-fill `BALANCE_REQ` in `canonicalInPlace` rejects an empty vault before its full-balance transfer;
a zero floor provides no positive-delivery guarantee. Conformance tests cover balances above/at/below
the reserve, zero-transfer recipient omission, and rejection by the canonical positive floor.

The integration suite derives relays from actual origin deposit events, binds `dst_step_id` to a destination root,
exercises both siblings and separately funded root reuse, and distinguishes safe consumption from deliberately
accepted unsafe primitives. Its aggregate examples prove or disprove delivery for concrete executions; they do not
authenticate all JIT variants of an aggregate production route. The canonical reference constructor only emits the
single-fill template. `fixtures/v5_gateway_path.json` additionally pins Borsh consumption-tape bytes, path hashes,
sorted sibling roots and witnesses across TypeScript, Rust and Solidity. Its placeholder keys are hashing fixtures,
not deployed token accounts. See [the lane guide](../../test/svm-gateway/README.md) for execution and companion docs.

## V4 entrypoint retirement and destination actions

`adapter_execute_across_v5` is the only deposit/fill entrypoint. `deposit`, `deposit_now`, `unsafe_deposit`,
`fill_relay`, and the legacy read-only `get_unsafe_deposit_id` utility are absent from the dispatch table, IDL, and
generated clients. Historical raw discriminators fail with Anchor's `InstructionFallbackNotFound` (101) before
argument decoding or account validation, including
empty-message fills and fills using instruction-parameter buffers. Slow-fill entrypoints are also retired.
All source deposits and destination fills must use the authenticated Gateway adapter.

The legacy `State.number_of_deposits` counter retains its value at upgrade and no longer advances on deposits.
V5 derives deposit IDs from the Gateway context and deposit nonce; it does not use the sequential counter.
Consumers must track successful `FundsDeposited` events and their V5 deposit IDs instead of using
`numberOfDeposits` as a deposit-progress signal. V5 deposits access the state account read-only; admin
instructions can still update state. The counter field and serialized state layout remain unchanged.

Legacy deposit IDs can still be computed off-chain as `keccak256(signer[32] || depositor[32] || nonce:u64_le)`.
V5 uses its separate Gateway/submitter/path-bound derivation; no live execution or historical cleanup depends on
the removed utility. Admin/root messaging, relayer refunds and claims, token-account creation, instruction-buffer
management, and fill-status rent reclaim remain available.
Existing account layouts and event schemas are unchanged; legacy fill-status accounts can still be closed after
expiry to their recorded rent recipient. Previously prepared fill-parameter buffers can be closed by their creator.
Sequential deposit-ID allocation, legacy fill-status transitions, and V4 delegate-seed helpers are removed from
the execution code; their historical account fields and event enum slots remain available for decoding.

Public clients expose encoder, decoder, and codec factories for all three V5 payload roots:

- `SvmSpokeClient.getV5AdapterInputEncoder()` encodes the committed `input`, including the `DepositV1` or `FillV1`
  enum tag and the selected variant's fields.
- `SvmSpokeClient.getAcrossDepositJitParamsEncoder()` encodes deposit `jit_data`: modified output amount,
  exclusive relayer, and a fixed 65-byte signature (129 bytes total). Deposits without modification rules can
  supply empty JIT bytes because that path does not decode them.
- `SvmSpokeClient.getV5FillJitEncoder()` encodes fill `jit_data`: `{ relayData, repaymentChainId, repaymentAddress }`.

All are Borsh payloads without account discriminators; replace `Encoder` with `Decoder` or `Codec` for the
matching factories. The `RelayData` type and `getRelayDataEncoder/Decoder/Codec` exports also remain available.
The retired `FillRelayParams` account/type and its generated codecs are removed; its account encoding is not
the V5 JIT format. Existing instruction buffers remain closable without deserializing that retired account type.

The `web3-v1` package subpath and its `helpers` module also remove these V4-only exports:

- `getDepositSeedHash`, `getDepositPda`, `getDepositNowSeedHash`, and `getDepositNowPda`;
- `getFillRelayDelegateSeedHash` and `getFillRelayDelegatePda`;
- `DepositSeedData` and `DepositNowSeedData`.

These helpers derived delegates for the removed instructions. Consumers must migrate to the authenticated V5
adapter and its source/fill delegate rules above. The V4 buffer builders `loadFillRelayParams` and
`createFillRelayParamsInstructions` are also removed. `getSolanaChainId`, `isSolanaDevnet`, relay hashing, refund and
generic instruction-buffer helpers remain available. Generated `get_unsafe_deposit_id` instruction builders and
codecs are removed with the endpoint.

Anchor cannot discover these schemas through the adapter's `Vec<u8>` argument. The standard production/test
IDL generation scripts include `V5AdapterInput`, `AcrossDepositJitParams`, `V5FillJit`, and their dependencies
using their Rust `IdlBuild` derives, then regenerate Anchor types and Codama clients. The published IDL contains
the complete schemas, so SDK-side Codama generation needs no extra schema injection or handwritten codecs.
The intended package boundary is for contracts to publish the IDL and the SDK to generate and export production
clients. Contracts currently also publishes generated clients; making those development-only is a separate migration.
Use `yarn generate-svm-artifacts` for public assets and `yarn generate-svm-test-idls` for target-only test IDLs.
A bare `anchor idl build` does not include these extra wire schemas; after a manual Spoke IDL build, run
`yarn ts-node scripts/svm/buildHelpers/includeV5IdlTypes.ts`.

Runtime error ranges are distinct: `CommonError` starts at 6000, `SvmError` at 7000, `V5Error` at 8000, and
`CallDataError` at 9000. Existing `CommonError` codes are unchanged; SVM/CCTP errors are renumbered from their overlapping
legacy range, and V5 errors are new in this release. The [runtime-code mapping](ERROR_CODES.md) compares this
release with deployed `v5.0.12-beta.1`, including removed variants and reserved slow-fill slots. V4 retirement removes
`InvalidRelayHash`, `InconsistentOptionalParameters`, `V5FillOnly`, and `LegacyFillMessageUnsupported`, plus their
orphaned message-validation helpers. Existing `CommonError` assignments remain 6000–6015; the final SVM range is
7000–7016. Intermediate undeployed stack values are not compatibility constraints. Tests pin the range endpoints
and the deployed slow-fill slots retained to keep later `CommonError` assignments unchanged.
Anchor 0.31.1's existing multi-enum IDL error generation remains incomplete, omits `SvmError`, and does not reflect
the explicit runtime offsets. Consumers should use runtime log names or the version-appropriate runtime-code
mapping; generated error-name tables alone are insufficient. Assigning distinct runtime ranges does not fix the
generated IDL table.

V5 keeps the relay witness in `RelayData.message` as exactly `V5_MAGIC_PREFIX || stepId`; `V5FillInput` omits a
separate callback message. The replacement destination flow is Gateway `APPROVE(inputMint, v5_fill_delegate, full balance)`,
a single in-place Across fill, then `APPROVE(inputMint, executor_authority, full balance)`, `CALL(swap)`, a committed
output-mint `BALANCE_REQ`, and a full-balance `TRANSFER` to the committed recipient. The swap sends output to the
Gateway output vault.
The vault owner signs only Gateway token operations; the swap receives its distinct SPL delegate as signer.
A failed swap or output floor reverts the entire execution, including the fill and payer rent.

Full-balance `APPROVE`, 100%-bps `BalanceSub`, and terminal `TRANSFER` follow EVM V5's full-balance semantics and
delivery policy. Builders must bind proportional or authenticated aggregate delivery to every recorded fill's
actual output amount, as described above. The fixture exercises the single-fill template with empty initial
input/output vaults and complete consumption; other routes must satisfy the same V5 delivery policy.

The [real-Gateway suite](../../test/svm-gateway/README.md) pins and exercises a concrete compatible swap program.
It covers one fill and one committed swap, not arbitrary JIT routes or aggregate fills. Production builders must
bind the complete destination outcome to every matching relay, validate venue instruction/version compatibility,
and retain any auction winner and bid requirements outside a JIT swap window. Separate relayer/swapper executions
can use prefunded chaining; they are distinct from this atomic fill-and-swap fixture.

### Deployment sequencing

Before deploying slow-fill retirement as part of the Lite-chain upgrade, verify the active dataworker and
configuration exclude Solana slow fills. The SDK excludes slow fills to/from Lite chains and requires token
equivalence through pool-rebalance routes. Lite-chain classification uses each deposit's quote timestamp;
today's classification does not establish that older deposits were excluded.

The shutdown reconciliation established that known in-flight user transfers were completed or refunded; it is
not an outstanding V4 fill obligation for this rollout. Keep remaining relayer repayments, deferred claims, and
incident root cleanup separate from that completed reconciliation. Any recovery relying on execution/return paths
being removed needs completion before the upgrade or a separately reviewed replacement. The combined upgrade rejects
nonzero `amount_to_return` and removes
`bridge_tokens_to_hub_pool`, so ordinary return processing cannot recover residual Solana funds afterward.
Unfilled deposits targeting Solana retain their input funds on their origin chains and are refunded there after
expiry; they do not explain a residual Solana vault balance. Solana-origin deposit refunds, relayer repayments,
deferred claims, and other vault funds need their own accounting. Preserve backing for outstanding claims and
repayments: the upgrade does not require an empty vault or withdrawal of every deferred claim, since refund/claim
instructions remain available. An expired fill-status account alone proves neither an unpaid deposit nor a completed
refund. Record settlement evidence separately from status-account rent cleanup.

Before deploying V4 entrypoint retirement and the error-code migration:

1. Keep V4 intent routes to and from Solana disabled in API/builders and coordinate relayer cutover to the
   replacement V5 path. Keep both `paused_deposits` and `paused_fills` set through the upgrade. Legacy
   `request_slow_fill` checks `paused_fills`, so maintaining that pause also prevents new requested-state PDAs.
   Backend route disablement alone does not prevent direct deposits on other origin chains.
2. Retain the completed shutdown reconciliation and refund evidence in the deployment record. No additional
   pre-shutdown V4 fill/refund reconciliation or resumption of legacy fills is required for this cutover.
   Any newly identified direct deposit after route disablement is a separate exception to assess, not a reason
   to reopen the settled shutdown backlog.
3. Carry forward the completed finalized-state check showing no unexpired `RequestedSlowFill` accounts, with its
   slot and deadline results in the deployment record. No repeat enumeration is needed while fills remain paused.
   If fills are unpaused before legacy retirement, refresh the check and resolve any conflict with fixed or
   already-emitted V5 relay hashes before enablement.
4. Inspect off-chain consumers for hardcoded numeric errors and update affected maps before upgrading: `SvmError`
   moves from 6000 to 7000 and `CallDataError` from 6000 to 9000; existing `CommonError` codes are unchanged.
   Earlier undeployed V5 integrations must use the final 8000 range. Consumers matching runtime log names need no
   renumbering change. Use the [migration table](ERROR_CODES.md), including its historical-error guidance. Audit
   numeric maps by inspection: a stale 6xxx mapping can silently mislabel a preserved Common error, so waiting for
   an observable failure is insufficient. Complete this coordination before deployment, including non-callback paths.
5. Publish the updated IDL and generated clients with the audited V5 release under a new package version in the
   planned v6 major release. Any intervening prerelease publication must also use a new prerelease version.
   The `rentRecipient` renames require consumer source updates when adopting the new clients; existing clients
   remain binary-compatible with these renames.
6. Deploy with both pause flags still set and verify legacy deposit/fill and slow-fill selectors are absent from
   the deployed program. Validate replacement V5 route-building and relayer execution support before unpausing
   deposits/fills and enabling V5 routes. Ensure any enabled cleanup client passes the recorded rent recipient for
   V5 accounts (the submitter's payer PDA), keeping the transaction fee payer separate. This is a V5 backend
   readiness requirement; existing legacy rent cleanup does not depend on it. The pause flags are shared by V4
   and V5; unpausing before legacy entrypoint retirement would reopen the old paths.

After the upgrade, V4 deposits cannot be filled on Solana. Slow fills are also retired;
any new unsupported V4 deposit follows the normal origin-chain expiry-refund process, not a destination fallback. HubPool chain
enablement does not guarantee that an arbitrary V4 deposit to Solana is fillable. API/builders and relayers must
require the supported V5 path, including for empty-message transfers.
The standalone MulticallHandler program and its package exports remain available to existing consumers; their
retirement and any deployed-program closure require a separate decision.
