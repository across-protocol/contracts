# SVM SpokePool V5 adapter specification (wire version 1)

This document freezes the compatibility surface for the Gateway-facing `svm_spoke` V5 adapter. It intentionally
describes foundations only: wire version 1 does not become callable until the source and destination behavior steps
land.

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
cross-VM uint256 values remain 32-byte big-endian EVM words.

Deposit JIT uses the EVM-aligned name `AcrossDepositJitParams` and is present exactly when the committed 20-byte
authority is nonzero and at least one modification is permitted. It is the fixed 129 bytes
`new_output_amount[32] || new_exclusive_relayer[32] || signature[65]`. A zero authority requires both permission
booleans false and empty `jit_data`; it never means permissionless modification. Fill mode always decodes `jit_data`
as `V5FillJit`. Malformed enum tags, invalid Borsh booleans or lengths, unsupported versions, missing required JIT,
and trailing bytes fail closed.

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
standing float. Only that submitter may withdraw the float to itself; a nonzero remainder must be rent-exempt, and
`u64::MAX` means withdraw the live balance. V5 fills emit the existing `FilledRelay` schema and derive the relay hash
from the supplied standard `RelayData` and the configured SVM chain ID. Adapter mode requires an empty callback
message; the relay witness remains exactly `V5_MAGIC_PREFIX || step_id`.

Transfer-fee mints are excluded until debit/delivery delta semantics are defined. Transfer hooks remain disabled
unless validator tests prove the complete hook-account set and the Gateway-to-Spoke CPI depth for that mint.

Golden values in `fixtures/v5_adapter_v1.json` are independently checked from Rust, TypeScript, and Solidity.
