# Cross-Chain Counterfactual Address Proposal

## Goal

Today, a counterfactual deposit address is unique per `(srcChain, srcToken, dstChain, dstToken, recipient, …)`. We want to relax that so:

1. **Same address across every supported EVM source chain** for a given destination identity.
2. **Any supported input token** on the source side maps to the same address, as long as it ultimately delivers a fixed `(dstChain, dstToken, recipient)` on the destination.

The "address identity" the user remembers becomes the destination, not the source: _"send funds (any chain, any supported token) to this address — they all arrive as `dstToken` for `recipient` on `dstChain`."_

## Current architecture (recap)

The CREATE2 clone address depends on:

```
address = f(factory, salt, initCode)
initCode = EIP-1167 proxy bytecode || abi.encode(merkleRoot)
```

The merkle root commits to the clone's authorized actions. Each leaf is currently:

```
leaf = keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))))
```

Two things make addresses differ across source chains today:

1. **Implementation addresses differ per chain.** `CounterfactualDepositSpokePool`/`CCTP`/`OFT` have chain-specific constructor immutables (`spokePool`, `srcPeriphery`, `signer`, `wrappedNativeToken`, `sourceDomain`, `srcEid`). Different bytecode → different deployed address → different leaf → different root → different clone address.
2. **Token addresses differ per chain.** `inputToken` / `burnToken` / `token` in the route params are chain-specific.

The naive fix is a chain-config registry contract whose values are read at execute time, but that imposes operational risk (wrong value in the registry silently redirects funds) and an SLOAD per execute.

## Proposal

Two contract changes plus a tree-construction discipline.

### 1. Bind `block.chainid` into the merkle leaf

Update the leaf preimage in `CounterfactualDeposit.sol`:

```solidity
bytes32 leaf = keccak256(
    bytes.concat(
        keccak256(abi.encode(block.chainid, implementation, keccak256(params)))
    )
);
```

Off-chain, the merkle tree contains one leaf per `(srcChainId, implementation, params)` tuple — the cross-product of every chain the address should support. Because the tree is identical on every chain, the root is identical, so the clone address is identical.

The dispatcher forces `block.chainid` into the leaf preimage (not caller-supplied), so a chain-A leaf cannot be replayed on chain B.

### 2. Cross-product over input tokens

The tree also enumerates supported input tokens per chain. Each bridge encodes the destination chain in its own identifier (SpokePool uses `destinationChainId`, CCTP uses `destinationDomain`, OFT uses `dstEid`), and every leaf in a single tree must resolve to the same logical destination — illustrated below with HyperEVM as the destination:

```
Leaf format: (block.chainid, implementation, params)

(1,     CCTPImpl_mainnet,      {burnToken=USDC_mainnet,  destinationDomain=HYPER_DOMAIN,    finalToken=USDC_hyper,     finalRecipient=X, …})
(1,     SpokePoolImpl_mainnet, {inputToken=USDT_mainnet, destinationChainId=HYPER_CHAINID, outputToken=USDC_hyper,    recipient=X,      …})
(1,     SpokePoolImpl_mainnet, {inputToken=ETH,          destinationChainId=HYPER_CHAINID, outputToken=USDC_hyper,    recipient=X,      …})
(42161, CCTPImpl_arb,          {burnToken=USDC_arb,      destinationDomain=HYPER_DOMAIN,    finalToken=USDC_hyper,     finalRecipient=X, …})
(42161, SpokePoolImpl_arb,     {inputToken=USDT_arb,     destinationChainId=HYPER_CHAINID, outputToken=USDC_hyper,    recipient=X,      …})
(42161, OFTImpl_arb,           {token=someOFT_arb,       dstEid=HYPER_EID,                  finalToken=USDC_hyper,     finalRecipient=X, …})
…
(1,     WithdrawImplementation, {admin, user})  // replicated per-chain — see §4
(42161, WithdrawImplementation, {admin, user})
…
```

Tree size grows linearly with `srcChains × inputTokens × bridges`. With ~10 EVM chains × ~3 input tokens × ~2 bridges ≈ 60 leaves (proof depth 6). Tiny in practice.

**Destination-identifier mapping is a backend responsibility.** "HyperEVM" maps to a `destinationChainId` for SpokePool, a `destinationDomain` for CCTP, and a `dstEid` for OFT. The SDK must hold the canonical mapping `dstChain → (destinationChainId, destinationDomain, dstEid)` and use it when constructing leaves. A wrong mapping for one bridge means the leaf for that bridge points at a different destination than the others — the on-chain code can't detect this, since each leaf's destination field is opaque to the dispatcher. See the backend implications section for how to defend against this.

Tree size grows linearly with `srcChains × inputTokens × bridges`. With ~10 EVM chains × ~3 input tokens × ~2 bridges ≈ 60 leaves (proof depth 6). Tiny in practice.

### 3. Bind the SpokePool signature to the route

The current `CounterfactualDepositSpokePool` typehash covers only execution-time fields:

```solidity
"ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
```

It does _not_ bind to `params`. Today the system relies on the rule "no duplicate implementation per clone" (see `README.md`) to prevent a relayer from proving leaf A's params while submitting a signature the signer issued for leaf B's route.

To allow multiple SpokePool leaves per clone (which is required for "any input token"), bind the route into the typehash:

```solidity
"ExecuteDeposit(bytes32 paramsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)"
```

The implementation derives `paramsHash = keccak256(params)` from its own argument and folds it into the EIP-712 struct hash. A leaf-A signature is no longer accepted for leaf-B params.

**CCTP and OFT need no change**: their signatures are verified by the `SrcPeriphery` against a signed quote that already includes the full route (`burnToken`, `mintRecipient`, `finalToken`, `finalRecipient`, etc.). The periphery rejects a swapped-route signature on its own. Multiple CCTP/OFT leaves per clone are already safe today.

### 4. Withdraw leaf

Two clean options:

- **Replicate per chain**: one `WithdrawImplementation` leaf per supported chain, each with `chainId = block.chainid` for its chain, all sharing the same `(admin, user)`. Trivial — adds 10–20 leaves to a tree that's already padded to a power of 2.
- **Sentinel `chainId = 0`**: special-case the dispatcher so `WithdrawImplementation` leaves with `chainId = 0` validate without binding. One leaf for all chains, but introduces a wildcard branch that must be tightly scoped to `WithdrawImplementation`.

Default: **replicate per chain**. Cleaner audit, no wildcards.

### 5. Optional — on-chain destination-identity invariance

The user's promise — _"every path in this tree lands at the same `(dstChain, dstToken, recipient)`"_ — is enforced today by the SDK / tree builder. Anyone can audit by enumerating leaves.

If we want on-chain enforcement (defense-in-depth against compromised tree builders), split the clone's immutable args into:

```
abi.encode(destinationIdentityHash, merkleRoot)
```

where `destinationIdentityHash = keccak256(dstChain, dstToken, recipient)`. The dispatcher requires each leaf to commit to the same `destinationIdentityHash`. Clone size grows from ~77 bytes to ~109 bytes (~6k extra gas at deploy).

This is most attractive if integrators (e.g. Coinbase, Native) generate addresses for end users — the integrator no longer needs to be trusted to construct trees correctly.

## Worked example: full tree for one destination identity

A concrete example, to make the cross-product tangible.

### Setup

**Destination identity (defines the clone address):**

- `dstChain = HyperEVM`
  - `destinationChainId = 999` (used by SpokePool leaves)
  - `destinationDomain = 13` (used by CCTP leaves — illustrative value)
- `dstToken = USDC_hyper` (the USDC contract on HyperEVM)
- `recipient = 0xRECIP`

**Withdraw config:**

- `admin = 0xADMIN` (the `AdminWithdrawManager`, deterministic-deployed to the same address on every EVM chain)
- `user = 0xUSER`

**Supported source chains:** Ethereum (1), Arbitrum (42161), Base (8453), Optimism (10), Polygon (137), Avalanche (43114)

**Supported input tokens:** USDC, USDT, WETH, WBTC

**Bridges enumerated per chain:**

- SpokePool: all 4 input tokens (relayer fills with USDC at destination, eating the swap)
- CCTP: USDC only (CCTP is USDC-native)

**Per chain:** 4 SpokePool leaves + 1 CCTP leaf + 1 withdraw leaf = 6 leaves.
**Total:** 6 chains × 6 = **36 leaves**, padded to 64 (tree depth 6, proofs are 6 hashes / 192 bytes).

### The 36 leaves

Leaf preimage: `keccak256(bytes.concat(keccak256(abi.encode(chainId, implementation, keccak256(params)))))`

> **The table below is abbreviated.** It shows only the route-defining fields per leaf (chain, implementation, input token, destination identifier, output/final token, recipient). The actual `params` struct passed into each leaf is much wider — see "What a leaf's `params` actually contains" below for a fully-decoded example.

| #     | chainId (src) | Bridge    | Implementation                                | Input token (on src)        | Destination encoding     | Dst token                 | Recipient                    |
| ----- | ------------- | --------- | --------------------------------------------- | --------------------------- | ------------------------ | ------------------------- | ---------------------------- |
| 0     | 1             | SpokePool | `SpokePoolImpl_eth`                           | `USDC_eth` (0xA0b8…eB48)    | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 1     | 1             | SpokePool | `SpokePoolImpl_eth`                           | `USDT_eth` (0xdAC1…1ec7)    | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 2     | 1             | SpokePool | `SpokePoolImpl_eth`                           | `WETH_eth` (0xC02a…56Cc)    | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 3     | 1             | SpokePool | `SpokePoolImpl_eth`                           | `WBTC_eth` (0x2260…C599)    | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 4     | 1             | CCTP      | `CCTPImpl_eth`                                | `USDC_eth` (burnToken)      | `destinationDomain=13`   | `USDC_hyper` (finalToken) | `0xRECIP` (finalRecipient)   |
| 5     | 42161         | SpokePool | `SpokePoolImpl_arb`                           | `USDC_arb` (0xaf88…5831)    | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 6     | 42161         | SpokePool | `SpokePoolImpl_arb`                           | `USDT_arb` (0xFd08…Fcbb)    | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 7     | 42161         | SpokePool | `SpokePoolImpl_arb`                           | `WETH_arb` (0x82aF…Fbab)    | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 8     | 42161         | SpokePool | `SpokePoolImpl_arb`                           | `WBTC_arb` (0x2f2a…5B0f)    | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 9     | 42161         | CCTP      | `CCTPImpl_arb`                                | `USDC_arb`                  | `destinationDomain=13`   | `USDC_hyper`              | `0xRECIP`                    |
| 10    | 8453          | SpokePool | `SpokePoolImpl_base`                          | `USDC_base` (0x8335…2913)   | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 11    | 8453          | SpokePool | `SpokePoolImpl_base`                          | `USDT_base` (0xfde4…9bb2)   | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 12    | 8453          | SpokePool | `SpokePoolImpl_base`                          | `WETH_base` (0x4200…0006)   | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 13    | 8453          | SpokePool | `SpokePoolImpl_base`                          | `cbBTC_base` (0xcbB7…33Bf)  | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 14    | 8453          | CCTP      | `CCTPImpl_base`                               | `USDC_base`                 | `destinationDomain=13`   | `USDC_hyper`              | `0xRECIP`                    |
| 15    | 10            | SpokePool | `SpokePoolImpl_op`                            | `USDC_op` (0x0b2C…Ff85)     | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 16    | 10            | SpokePool | `SpokePoolImpl_op`                            | `USDT_op` (0x94b0…8e58)     | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 17    | 10            | SpokePool | `SpokePoolImpl_op`                            | `WETH_op` (0x4200…0006)     | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 18    | 10            | SpokePool | `SpokePoolImpl_op`                            | `WBTC_op` (0x68f1…2095)     | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 19    | 10            | CCTP      | `CCTPImpl_op`                                 | `USDC_op`                   | `destinationDomain=13`   | `USDC_hyper`              | `0xRECIP`                    |
| 20    | 137           | SpokePool | `SpokePoolImpl_poly`                          | `USDC_poly` (0x3c49…3359)   | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 21    | 137           | SpokePool | `SpokePoolImpl_poly`                          | `USDT_poly` (0xc213…8e8F)   | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 22    | 137           | SpokePool | `SpokePoolImpl_poly`                          | `WETH_poly` (0x7ceB…f619)   | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 23    | 137           | SpokePool | `SpokePoolImpl_poly`                          | `WBTC_poly` (0x1BFD…BfD6)   | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 24    | 137           | CCTP      | `CCTPImpl_poly`                               | `USDC_poly`                 | `destinationDomain=13`   | `USDC_hyper`              | `0xRECIP`                    |
| 25    | 43114         | SpokePool | `SpokePoolImpl_avax`                          | `USDC_avax` (0xB97E…8a6E)   | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 26    | 43114         | SpokePool | `SpokePoolImpl_avax`                          | `USDT_avax` (0x9702…A8c7)   | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 27    | 43114         | SpokePool | `SpokePoolImpl_avax`                          | `WETH.e_avax` (0x49D5…0bAB) | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 28    | 43114         | SpokePool | `SpokePoolImpl_avax`                          | `WBTC.e_avax` (0x50b7…B218) | `destinationChainId=999` | `USDC_hyper`              | `0xRECIP`                    |
| 29    | 43114         | CCTP      | `CCTPImpl_avax`                               | `USDC_avax`                 | `destinationDomain=13`   | `USDC_hyper`              | `0xRECIP`                    |
| 30    | 1             | Withdraw  | `WithdrawImpl`                                | —                           | —                        | —                         | `admin=0xADMIN, user=0xUSER` |
| 31    | 42161         | Withdraw  | `WithdrawImpl`                                | —                           | —                        | —                         | `admin=0xADMIN, user=0xUSER` |
| 32    | 8453          | Withdraw  | `WithdrawImpl`                                | —                           | —                        | —                         | `admin=0xADMIN, user=0xUSER` |
| 33    | 10            | Withdraw  | `WithdrawImpl`                                | —                           | —                        | —                         | `admin=0xADMIN, user=0xUSER` |
| 34    | 137           | Withdraw  | `WithdrawImpl`                                | —                           | —                        | —                         | `admin=0xADMIN, user=0xUSER` |
| 35    | 43114         | Withdraw  | `WithdrawImpl`                                | —                           | —                        | —                         | `admin=0xADMIN, user=0xUSER` |
| 36–63 | —             | —         | padding (`keccak256("padding")` or `0x00…00`) | —                           | —                        | —                         | —                            |

### What a leaf's `params` actually contains

The table above is the route-defining slice. The full `params` struct for each leaf includes all fee policy, slippage limits, fill-deadline behavior, execution-fee handling, etc. For example, **leaf #6** (Arbitrum, SpokePool, USDT → USDC_hyper) decodes to:

```solidity
SpokePoolDepositParams({
    destinationChainId: 999,
    inputToken:         bytes32(uint256(uint160(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9))),  // USDT_arb
    outputToken:        bytes32(uint256(uint160(USDC_hyper))),
    recipient:          bytes32(uint256(uint160(0xRECIP))),
    message:            "",
    stableExchangeRate: 1e18,            // USDT ≈ USDC for fee-cap arithmetic
    maxFeeFixed:        2_000_000,       // 2 USDT (6 decimals) fixed-fee headroom
    maxFeeBps:          20,              // 0.20% variable-fee cap
    executionFee:       500_000          // 0.5 USDT execution fee (or dynamic; see Change #1)
})
```

And **leaf #4** (Ethereum, CCTP, USDC → USDC_hyper) decodes to:

```solidity
CCTPDepositParams({
    destinationDomain:    13,                                   // HyperEVM CCTP domain (illustrative)
    mintRecipient:        bytes32(uint256(uint160(DstPeriphery_hyper))),
    burnToken:            bytes32(uint256(uint160(USDC_eth))),
    destinationCaller:    bytes32(uint256(uint160(permissionedBot))),
    cctpMaxFeeBps:        10,                                   // 0.10% CCTP fee cap
    minFinalityThreshold: 1000,
    maxBpsToSponsor:      50,                                   // relayer may sponsor up to 0.50%
    maxUserSlippageBps:   30,                                   // 0.30% destination slippage
    finalRecipient:       bytes32(uint256(uint160(0xRECIP))),
    finalToken:           bytes32(uint256(uint160(USDC_hyper))),
    destinationDex:       0,                                    // not used (DirectToCore mode)
    accountCreationMode:  0,                                    // Standard
    executionMode:        0,                                    // DirectToCore
    actionData:           "",
    executionFee:         500_000                               // 0.5 USDC execution fee
})
```

And **leaf #31** (Arbitrum, Withdraw) decodes to:

```solidity
WithdrawParams({
    admin: 0xADMIN,
    user:  0xUSER
})
```

Every field in `params` is part of `keccak256(params)`, and `keccak256(params)` is what gets committed in the leaf preimage. So a single byte change in any field — `maxFeeFixed`, `executionFee`, `actionData`, anything — produces a different leaf, a different root, and a different clone address.

### How a deposit flows through this tree

User funds the predicted clone address on Arbitrum with 100 USDT. A relayer watching Arbitrum sees the balance and decides to fill:

1. Look up the address record → destination identity + policy version.
2. Regenerate the tree (deterministic from inputs).
3. Identify the matching leaf: **#6** (Arbitrum, SpokePool, USDT).
4. Build a Merkle proof for leaf #6 (6 sibling hashes).
5. Call `factory.deployIfNeededAndExecute(SpokePoolImpl_arb, paramsHash_6, salt, executeCalldata)` or `clone.execute(SpokePoolImpl_arb, params_6, submitterData_6, proof_6)`.

The dispatcher in `CounterfactualDeposit.execute()` does:

```solidity
bytes32 leaf = keccak256(
    bytes.concat(
        keccak256(abi.encode(
            block.chainid,             // 42161 — forced, not caller-supplied
            implementation,            // SpokePoolImpl_arb
            keccak256(params)          // hashes leaf #6's full params
        ))
    )
);
require(MerkleProof.verify(proof, merkleRoot, leaf));
implementation.delegatecall(abi.encodeCall(...));
```

What this prevents:

- **Cross-chain replay.** If the relayer submitted leaf #6's proof on Base, `block.chainid` would be 8453 → leaf hash differs → proof fails.
- **Implementation substitution.** If the relayer substituted `SpokePoolImpl_eth` while proving leaf #6 → `implementation` differs → leaf hash differs → proof fails.
- **Route swap via shared signer.** If the relayer claimed the USDC route (#5) but submitted a SpokePool signature signed for the USDT route (#6) — under the **new `paramsHash`-bound EIP-712 typehash**, the signature is invalid for leaf #5's params, so `_verifySignature` reverts.

### What the backend has to keep handy for this one address

- The destination triple `(999, USDC_hyper, 0xRECIP)` plus policy version.
- The policy file, which yields the 36 logical leaves above (with real per-chain implementation and token addresses).
- That's it — the tree, root, clone address, and any leaf's proof regenerate from those inputs in milliseconds.

Multiplied across the user base: one of these per `(recipient, dstChain, dstToken)` issued.

## Contract-side diff (summary)

| Change                                                     | File                                                            | Approx size |
| ---------------------------------------------------------- | --------------------------------------------------------------- | ----------- |
| `block.chainid` in leaf preimage                           | `CounterfactualDeposit.sol`                                     | 1 line      |
| `paramsHash` in SpokePool EIP-712 typehash + struct hash   | `CounterfactualDepositSpokePool.sol`                            | ~10 lines   |
| Per-chain withdraw leaf convention                         | docs / SDK                                                      | docs        |
| (Optional) `destinationIdentityHash` immutable arg + check | `CounterfactualDeposit.sol`, `CounterfactualDepositFactory.sol` | ~30 lines   |
| Drop "no duplicate impl per clone" rule                    | `README.md`                                                     | docs        |

No new contracts. No storage. No registry. No SLOADs per execute.

## What this gets you vs. a chain-config registry

| Property                                     | Registry approach                                      | This proposal                                                                  |
| -------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------ |
| Same clone address across EVM chains         | Yes                                                    | Yes                                                                            |
| Per-execute gas overhead                     | SLOADs + cold reads                                    | None                                                                           |
| Operational config to maintain across chains | Yes (one source of truth, every chain)                 | None                                                                           |
| Failure mode if value is wrong               | Funds silently routed wrong                            | Clone address derives differently → no funds get sent there in the first place |
| Audit surface                                | New registry contract + admin model + refactored impls | One leaf format change + one EIP-712 binding                                   |

The failure-mode column is the important one: with a registry, a stale entry on chain X causes user funds to land at the same address but bridge somewhere unintended. With chainId-in-leaf, a wrong off-chain value produces a different clone address upfront — the failure is loud, not silent.

## Caveats

1. **Adding a new chain later requires a new address.** Same constraint as today's "params are immutable after deployment." Users wanting future-chain support must regenerate.
2. **Tron stays a carveout.** `CounterfactualDepositFactoryTron` uses CREATE2 prefix `0x41` vs `0xff` on EVM. Same merkle root → different address on Tron. Already documented; not changed by this proposal.
3. **Per-bridge token reach is bounded.** CCTP can only bridge USDC; OFT can only bridge specific OFT tokens; SpokePool can take any input token Across has relayer liquidity for (with destination-side fill semantics). The "any input token" guarantee is only as broad as the SDK actually emits leaves for.
4. **Each implementation must already be deployed** on every chain referenced by the tree, before address generation. Today's deployment flow already lands the per-chain impls deterministically; nothing new operationally.
5. **EIP-712 cross-chain replay is not a concern.** OZ's `_hashTypedDataV4` mixes `block.chainid` into the domain separator at call time, so a SpokePool signature for chain A doesn't validate on chain B regardless of clone-address sameness.

## Backend / SDK / API implications

This is where most of the _non-contract_ work lands. Worth surfacing early.

### Address derivation

- **Cross-product enumeration.** The SDK must enumerate `(srcChain, inputToken, bridge)` tuples and build a merkle tree of the full cross-product. For each tuple, it must look up the chain-correct implementation address and the chain-correct token address. Today's "one route → one address" derivation logic becomes "set of routes → one address."
- **Per-chain implementation address registry.** Whatever package today computes counterfactual addresses must know the deployed `CounterfactualDepositSpokePool` / `CounterfactualDepositCCTP` / `CounterfactualDepositOFT` address on every supported chain. This is already in `broadcast/deployed-addresses.json`; the SDK needs a maintained mirror or a load path.
- **Per-chain token-address registry.** USDC's address on every supported chain, etc. Most teams already have a token list; this proposal makes accuracy load-bearing for address correctness.
- **Destination-identifier mapping per bridge.** "Destination = HyperEVM" must be translated to a `destinationChainId` for SpokePool leaves, a `destinationDomain` for CCTP leaves, and a `dstEid` for OFT leaves. The SDK owns this mapping; getting it wrong on a single bridge means that leaf's deposits silently route to a different destination than the user expected. If we adopt **Option B** (on-chain `destinationIdentityHash`), we should canonicalize the destination identity to one form (e.g. `chainId`) and have each bridge implementation translate from its native identifier into that canonical form for the on-chain check — otherwise a per-bridge identifier mismatch passes the check trivially.
- **Mismatch failure mode.** If the SDK uses a wrong implementation or token address for a chain, the derived clone address is different from the canonical one. Funds sent by users will land at an address that _no_ relayer is watching, and recovery requires the user (or admin) to call withdraw against the clone they actually funded. The SDK should treat the deployed-addresses file as a single source of truth and version-pin it.

### API / quoting

- **Per-leaf quote semantics.** Today a quote covers one route. Now a single address has many possible routes; the quoting service must decide which leaves to advertise and how to price each. Likely there's a "preferred route" the user sees in the UI (e.g. cheapest), but the relayer can execute any leaf at runtime based on what's actually funded.
- **Quote signing.** The SpokePool signature now binds to `paramsHash`. Quote-signing infrastructure must produce one signature per `(leaf, executionTimeArgs)` it's quoting for. CCTP/OFT quotes are unchanged (they already bind to the route at the periphery).
- **Tree exposure for transparency.** If we stick with SDK-enforced destination invariance (Option A), the API should expose the full leaf list for any clone address so integrators / users can audit _"every path in this tree lands at my destination."_ If we adopt on-chain `destinationIdentityHash` (Option B), this exposure is a nice-to-have rather than a trust requirement.

### Relayer infrastructure

- **Multi-leaf, multi-chain watching.** A single clone address can receive funds on any source chain with any of multiple input tokens. Relayers must watch the same address on every supported chain and across the configured input-token set, executing whichever leaf matches what actually arrives.
- **Leaf-selection logic.** When a clone holds multiple input tokens simultaneously (e.g., user sent both USDC and USDT to the same address), relayers must decide which leaf(s) to execute and in what order. Today the leaf is implied by the funded token; with the change, the relayer still picks the matching leaf for each token, but must handle multiple sequential executes per clone.
- **Profitability across leaves.** With both SpokePool and CCTP routes available for USDC, the relayer picks whichever is more profitable. Off-chain relayer logic that today branches on bridge type per address must now branch per execute.
- **Funding-detection latency.** Watching N chains × M tokens per address is a fan-out increase. RPC / mempool / index strategy needs to scale, especially for popular addresses.

### Indexer / analytics

- **Address ↔ destination mapping is no longer 1:1 with a single deposit event.** Today, the deposit event tells you the source chain and input token. That's still true per execute, but the _address_ itself is shared across chains, so any "where did this user deposit?" question must aggregate across chains.
- **Backfill considerations.** Existing counterfactual addresses derive under the old leaf format. They keep working as long as the dispatcher honors both leaf formats during a migration window, or — cleaner — the change is gated to a new factory deployment so old addresses remain on the old dispatcher. See "Migration" below.

### Withdraw and recovery

- **Per-chain proofs.** With the "replicate per chain" withdraw scheme, the admin/user supplies a chain-specific proof when withdrawing. The withdraw tooling (the `AdminWithdrawManager` direct/signed paths) needs to know which chain it's on and pick the right leaf.
- **Funds-on-wrong-chain recovery.** If a user funds the address on a chain the tree didn't include (e.g. they used Linea, which the SDK omitted), the clone is still deployable on Linea but no deposit leaf will validate there. Withdraw still works (per-chain withdraw leaves), so funds are not stuck — but the user has to explicitly withdraw rather than bridge. Documentation should be explicit about which chains are supported per address.

### Migration / rollout

- **Existing addresses do not migrate.** Old addresses derived with the current leaf format remain valid against the current contracts; they will not be re-derivable from the new dispatcher because the leaf format differs. Plan:
  1. Deploy the new `CounterfactualDeposit` dispatcher and (if Option B) a new `CounterfactualDepositFactory` at a fresh CREATE2 address.
  2. SDK switches new address generation to the new factory + dispatcher.
  3. Old addresses continue to be served by the old contracts; no funds at risk.
  4. Eventually deprecate generation against the old contracts once integrators have migrated.
- **No upgrade path for live clones.** EIP-1167 proxies aren't upgradeable. A user with a populated tree on the old format keeps their tree; they get a new address if they want the new properties.

## Open product questions

- Default input-token set per `(dstChain, dstToken)` — what's in the cross-product? (Affects tree size, relayer coverage, marketing claim.)
- Should we adopt **Option A** (SDK-enforced destination identity) or **Option B** (on-chain `destinationIdentityHash`)? B is cheap and gives integrators a hard guarantee; A is simpler.
- Is the "address regeneration when adding a new chain" tradeoff acceptable, or do we want a different design (e.g. a per-chain extension leaf that can be appended via signed root update — out of scope for this proposal)?

## Recommendation

Proceed with the chainId-in-leaf + SpokePool route binding change. It's a small, well-scoped contract delta that achieves both the cross-chain-address goal and the any-input-token goal without introducing a registry or storage reads. Sequence:

1. Align with product on **Option A vs. B** and the default input-token set.
2. Land contract changes + tests.
3. Audit (small scope — single dispatcher + one EIP-712 binding tweak).
4. SDK + API + relayer-infra updates in parallel with audit.
5. Deploy new contracts at fresh CREATE2 addresses; SDK cuts over.
