# SVM SpokePool V5 adapter specification (wire version 1)

This document freezes the compatibility surface for the Gateway-facing `svm_spoke` V5 adapter. Wire version 1
enables both `Deposit` and `Fill`.

## Dispatch ABI and accounts

The frozen dispatch target for the later behavior steps is the single
`adapter_execute_across_v5(ctx_values, input, jit_data)` entrypoint, whose Anchor discriminator is the first eight
bytes of `sha256("global:adapter_execute_across_v5")`. Gateway program
`34trBszXuqhRjWaMxXWsunJNmyUsBvDNPxAwTzbPTm4p` serializes:

```text
discriminator[8]
|| step_id[32] || path_id[32] || submitter[32]
|| input_len:u32_le || input
|| jit_len:u32_le || jit_data
```

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
`["v5_source_delegate"]`. Both vaults must be writable; the adapter creates no accounts and pays no rent.

## Committed input and JIT wire

`input` is strict Borsh with no trailing bytes:

```text
V5AdapterInput {
  version: u8 = 1,
  mode: enum { Deposit = 0(AcrossDepositInput), Fill = 1(V5FillInput) }
}
```

`AcrossDepositInput` nests the canonical deposit fields under `deposit_params: AcrossDepositParams`, matching the EVM
adapter's type boundary. Borsh serializes that fixed struct inline, so the nesting adds no bytes. All Rust fields
serialize in declaration order. Integers use Borsh little-endian encoding. Pubkeys and `[u8; 32]` are raw 32-byte
values. Vectors use a `u32_le` length. `input_amount_mode` is `Literal = 0` or
`InputVaultBalance = 1 { bips: u16_le }`; `bips` must not exceed 10,000. The resolved SVM token amount is `u64`, while
cross-VM uint256 values remain 32-byte big-endian EVM words. The leading version byte is checked before the mode body
is decoded, so any unsupported version reports `UnsupportedVersion` even when its body is not compatible with v1.

Gateway token vaults are shared per mint rather than isolated per execution. `InputVaultBalance` therefore resolves
against shared live state, and the continuing tape must leave no residual balance. Gateway does not currently enforce
this net-zero settlement invariant. The adapter binds the vault's delegate to `v5_source_delegate` and requires its
allowance to cover the resolved amount, but deliberately does not require equality: this matches the EVM
`transferFrom` behavior and accepts sufficient or maximum approvals. Any residual Gateway-vault balance is already
movable by a later committed Gateway `TRANSFER`; exact allowance would not replace that custody invariant. The
SpokePool never delegates its own vault.

Unlike the EVM `inputAmountParam`, SVM wire v1 has no set-call-value flag. Native SOL must first be wrapped by the
ordinary Gateway `WRAP_SOL` command into its canonical WSOL vault; the deposit then consumes WSOL through the same
token path as any SPL input. Direct lamport deposit from this adapter is outside wire v1.

Deposit JIT uses the EVM-aligned name `AcrossDepositJitParams` and is present exactly when the committed 20-byte
authority is nonzero and at least one modification is permitted. It is the fixed 129 bytes
`new_output_amount[32] || new_exclusive_relayer[32] || signature[65]`. A zero authority requires both permission
booleans false and empty `jit_data`; it never means permissionless modification. This intentionally diverges from
the EVM `AcrossDepositDelegateAdapter`, which permits authority-less JIT when a permission flag is set. Route builders
must not emit that EVM-only rule shape for SVM. Fill mode always decodes `jit_data` as `V5FillJit`. Malformed enum tags,
invalid Borsh booleans or lengths, unsupported versions, missing required JIT, and trailing bytes fail closed.

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

The configured executor is Gateway in version 1, but deposit identity deliberately takes `executor_program_id` while
the signature domain always takes `gateway_program_id`. Signatures are secp256k1 `r[32] || s[32] || v[1]`, accept
only `v` 27 or 28, require low `s`, recover an uncompressed public key, and compare the last 20 bytes of its Keccak
hash with the committed authority. ERC-1271, Ed25519, EIP-2098, high-`s`, and `v` 0/1 encodings are unsupported.

## PDA and token invariants

- Source delegate: `["v5_source_delegate"]` under `svm_spoke`; a preceding ordinary Gateway `APPROVE` may grant any
  allowance at least the resolved amount, including `u64::MAX`. `svm_spoke` later pulls exactly the resolved amount.
- External fill delegate: `["v5_fill_delegate"]` under `svm_spoke`; sufficient allowance is accepted and the exact
  JIT `output_amount` is pulled.
- Gateway vault authority: `["vault_authority"]` under Gateway. A Gateway vault is the canonical ATA of this authority,
  the mint, and the mint's token program.
- Fill status: the existing `["fills", relay_hash]` PDA under `svm_spoke`, preserving the standard replay namespace.
- Fill payer float: `["v5_fill_payer", submitter]` under `svm_spoke`. The data-less, system-owned PDA manually pays
  fill-status rent with `invoke_signed`; it is not a forwarded transaction signer.

An external delivery targets the canonical ATA of committed `recipient`, output mint, and token program. A canonical
Gateway-vault delivery validates that same live vault in place and its amount, records the fill, and performs no token
self-transfer or approval. The continuing atomic tape must consume the output.

Fill-status expiry reclaim is permissionless and closes back to the submitter-scoped payer PDA, replenishing its
standing float. Only that submitter may withdraw the float to itself. Partial withdrawals remain subject to Solana's
runtime rent-state rules, while `u64::MAX` withdraws the live balance. This also relaxes `close_fill_pda` for existing
fill-status accounts: old clients may continue supplying the recorded relayer signature, but it is no longer required.
The unchanged `FillStatusAccount.relayer` field stores the payer PDA for
V5 fills (legacy fills continue to store their relayer), binding permissionless reclaim to the float that paid the
rent without an account-layout migration. V5 fills emit the existing `FilledRelay` schema and derive the relay hash
from the supplied standard `RelayData` and the configured SVM chain ID. Adapter mode requires an empty callback
message; the relay witness remains exactly `V5_MAGIC_PREFIX || step_id`. As on EVM, V5-tagged relays are quarantined
from the slow-fill lifecycle, so their fill status can only transition directly from an uninitialized PDA to `Filled`.

Token-2022 mint extensions fail closed. Wire version 1 permits only mint-close authority and metadata/group pointer
or data extensions. Transfer fees remain excluded until debit/delivery delta semantics are defined; transfer hooks,
permanent delegates, default-frozen accounts, and all other extensions remain disabled unless their custody and CPI
semantics are explicitly reviewed and validator-tested. This gate covers mint extensions only. Account-side guards
relevant to this path, such as source CPI guard or destination memo requirements, fail the token transfer rather than
altering accounting.

## Enabled source-deposit behavior

After authenticating the live Gateway dispatch PDA, Deposit mode strictly decodes branch-specific JIT data, resolves
the input amount against the canonical Gateway vault, and pulls exactly the resolved amount into the pre-created
SpokePool vault. The token transfer enforces the static source delegate and sufficient allowance. The adapter applies
only signed, committed JIT modifications, derives the final 32-byte deposit ID directly from the Gateway executor
identity and live context, and emits the standard `FundsDeposited` event with
`message = V5_MAGIC_PREFIX || dst_step_id`. Any later failure in the same transaction rolls back the approval,
transfer, and event atomically.

## Enabled destination-fill behavior

Fill mode strictly decodes the JIT relay and repayment data, binds the recipient, output mint, minimum amount, and
exact `V5_MAGIC_PREFIX || step_id` witness to the committed input, and evaluates exclusivity against the
Gateway-attested submitter. It derives the canonical relay hash on-chain, creates the shared fill-status PDA from the
submitter's payer float, and emits the standard `FilledRelay` event with the original witness hash and an empty updated
message hash. The legacy and V5 entrypoints share the same internal `_fill` core for pause, exclusivity, deadline,
legacy replay/fill-type resolution, callback-mode event fields, and canonical event construction. Each handler retains
only its intentionally distinct funding, status-account creation, and callback mechanics.

External delivery requires a sufficient approval to `["v5_fill_delegate"]` and pulls exactly the JIT output amount
from the canonical Gateway vault into the committed recipient's ATA. When that recipient ATA is the canonical Gateway
vault itself, the adapter instead authenticates its live balance, records the fill in place, and performs no approval
or self-transfer; the continuing atomic tape must consume the output. Any later failure rolls back token, fill-status,
and payer-float changes together.

Golden values in `fixtures/v5_adapter_v1.json` are independently re-derived from Rust, TypeScript, and Solidity to
catch byte-width, packing, and endianness drift. These are cross-language self-consistency vectors, not an invocation
of the EVM adapter. The JIT digest layout matches `AcrossDepositDelegateAdapter`, while SVM deposit identity
necessarily uses a 32-byte executor program ID instead of EVM's 20-byte caller address.
