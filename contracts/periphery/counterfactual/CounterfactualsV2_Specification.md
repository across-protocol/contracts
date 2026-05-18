# Counterfactuals V2 Specification

## Requirements

1. **Address keying.** Each counterfactual deposit address is keyed to a unique `(outputToken, destinationChainId, recipient)` triple. Two different triples yield two different addresses; the same triple always yields the same address.

2. **Cross-chain consistency.** For a given `(outputToken, destinationChainId, recipient)` triple, the deposit address is identical on every supported EVM source chain. A user receives one address and can fund it from any supported source chain.

3. **Longevity.** Addresses are permanent. Once derived, an address remains valid indefinitely; it can receive and be executed against an unbounded number of times.

4. **Supported inputs.** A given address accepts a defined set of input tokens on the source side. For V2, supported input sets are:
   - **Same-asset:** `inputToken == outputToken` (e.g. ETH → ETH, WBTC → WBTC, USDC → USDC).
   - **Stable-to-stable:** `inputToken` and `outputToken` are both stablecoins from a maintained allowlist (e.g. USDC, USDT, USDe, USDG, and future additions).

5. **Unsupported inputs.** Tokens delivered to an address that are not in its supported-input set are refundable. The system must provide a non-trusted path for returning such tokens to the depositor.

6. **System evolution.** New functionality, new bridge integrations, new source chains, and new destination chains can be introduced over time. Existing addresses remain valid against the contract versions they were derived against. New addresses generated after a version cut can opt into new functionality. Funds at an existing address can be migrated to a new-version address by the address owner via the refund / withdraw path.

## Out of Scope (V2)

- **Volatile-to-stable** swaps (e.g. ETH → USDC).
- **Volatile-to-volatile** swaps (e.g. WBTC → ETH).
- **In-place upgrade** of an existing address's behavior. Once an address is derived, its merkle tree and the implementation addresses it points to are immutable; behavior cannot be retroactively expanded for that address. Migration to a new-version address is the supported evolution path.

The volatile-input cases are excluded because the fee-cap model assumes stable price ratios between `inputToken` and `outputToken`; volatile pairs would require either a different fee model or oracle-priced execution, both deferred.

## Summary

A V2 deposit address is a CREATE2-deployed EIP-1167 proxy whose sole immutable argument is a merkle root. The root commits to every action the address can authorize. The user (or an SDK on their behalf) constructs the tree from a declared policy `(outputToken, destinationChainId, recipient, supported-input-tokens, supported-source-chains, supported-bridges, fee bounds)`, computes the root, derives the CREATE2 address, and funds it.

Each leaf in the tree is a tuple `(block.chainid, implementation, keccak256(params))`. The dispatcher folds `block.chainid` into the preimage at execute time so the same tree authorizes different `(implementation, params)` tuples on different chains while preventing cross-chain replay. Because the dispatcher does not know which chain the address was used on until execute time, the same merkle root produces the same CREATE2 address on every EVM chain — satisfying the cross-chain consistency requirement.

The tree is constructed as the cross-product of supported source chains, supported input tokens, and supported bridges. For an example destination `(USDC on HyperEVM, recipient X)` supporting 6 source chains × 4 input tokens × 2 bridges, the tree contains approximately 36 deposit leaves plus per-chain withdraw leaves.

Execution proceeds as follows:

1. A user funds the predicted address on any supported source chain with a supported input token.
2. A relayer detects the funded balance, identifies the matching leaf, and constructs a merkle proof.
3. The relayer calls `factory.deployIfNeededAndExecute(...)` or `clone.execute(...)` with the leaf's `params`, the relayer's chosen `submitterData` (amounts, deadlines, dynamic execution fee, signatures), and the merkle proof.
4. The dispatcher verifies the merkle proof, then delegatecalls the implementation, which performs the bridge call.

Execution fees are dynamic. The fee is supplied by the relayer at execute time but only validates if a designated signer has signed an EIP-712 message binding the fee to the specific leaf and the specific input amount. A `maxExecutionFeeBps` field in `params` (committed to the merkle leaf) caps the maximum fee the signer can authorize, bounding the blast radius of a signer compromise.

Unsupported tokens delivered to an address are recoverable via the withdraw leaf, which authorizes both an `admin` address and a `user` address to sweep arbitrary tokens from the clone to any recipient. The `admin` is typically `AdminWithdrawManager`, which supports both a trusted bot for automated refunds and a permissionless signed-withdraw-to-user path.

System evolution is handled by deploying new contract versions and generating new addresses. Existing addresses point at immutable implementations and continue working against them. Users wanting new functionality regenerate their address against the new version; funds at an old address can be migrated via withdraw.

## Architecture

### Components

| Contract                         | Role                                                                                                                                                                                            |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CounterfactualDepositFactory`   | Bridge-agnostic deployer. CREATE2-deploys clones with the merkle root as the sole immutable arg. Exposes `deploy`, `predictDepositAddress`, `execute`, and combined deploy+execute entrypoints. |
| `CounterfactualDeposit`          | Merkle-dispatched proxy. All clones are EIP-1167 proxies of this contract. Verifies merkle proofs and delegatecalls the proven implementation.                                                  |
| `CounterfactualDepositSpokePool` | Across SpokePool deposit implementation. Verifies a local EIP-712 signature, enforces a fee cap, calls `SpokePool.deposit()`.                                                                   |
| `CounterfactualDepositCCTP`      | SponsoredCCTP deposit implementation. Verifies a local EIP-712 fee signature, enforces `maxExecutionFeeBps`, forwards to `SponsoredCCTPSrcPeriphery.depositForBurn()`.                          |
| `CounterfactualDepositOFT`       | SponsoredOFT (LayerZero) deposit implementation. Verifies a local EIP-712 fee signature, enforces `maxExecutionFeeBps`, forwards to `SponsoredOFTSrcPeriphery.deposit()`.                       |
| `WithdrawImplementation`         | Sweeps tokens / ETH from the clone. Authorized by either an `admin` or `user` address committed in the leaf's `WithdrawParams`. Provides the refund path for unsupported inputs.                |
| `AdminWithdrawManager`           | The contract typically set as `admin` in withdraw leaves. Supports direct withdraw by a trusted operator and permissionless signed withdraw to the user.                                        |

### Clone Layout

Each clone is 77 bytes: a 45-byte EIP-1167 proxy plus a 32-byte immutable arg (the merkle root). The factory deploys via `Clones.cloneDeterministicWithImmutableArgs(impl, abi.encode(merkleRoot), salt)`.

### Call Chain

```
Caller → CALL → Clone (EIP-1167 proxy)
              → DELEGATECALL → CounterfactualDeposit (dispatcher)
                             → verifies merkle proof
                             → DELEGATECALL → Implementation.execute(params, submitterData)
```

- `address(this)` = clone address throughout (correct for EIP-712 domain separator and token balances).
- `msg.sender` = the original caller throughout.
- `msg.value` = the original value throughout.

### Merkle Leaf Format

```
leaf = keccak256(bytes.concat(keccak256(abi.encode(block.chainid, implementation, keccak256(params)))))
```

`block.chainid` is folded into the preimage by the dispatcher at execute time — it is not caller-supplied. The dispatcher rebuilds the leaf using the chain's own `block.chainid`, so a leaf authorized for chain A cannot be replayed on chain B.

Double-hashing prevents leaf / internal-node ambiguity per the OpenZeppelin merkle standard.

## Address Identity Binding

The CREATE2 address is a deterministic function of `(factory, salt, initCode)`. The initCode embeds the merkle root. The merkle root commits to every leaf's `(block.chainid, implementation, keccak256(params))`. Each leaf's `params` includes the destination (`destinationChainId` + `outputToken` + `recipient` for SpokePool; `destinationDomain` + `finalToken` + `finalRecipient` for CCTP; `dstEid` + `finalToken` + `finalRecipient` for OFT).

A tree containing any leaf for a different destination produces a different root and therefore a different address. The user (or an auditor) verifies their address by reconstructing the canonical tree from their policy and confirming the CREATE2 address matches the SDK's claim. Once funded, the dispatcher's merkle-proof check guarantees only leaves actually in the tree can execute.

No separate on-chain "destination identity" immutable is required: the merkle root's binding into the CREATE2 address derivation provides the guarantee.

## Tree Construction

For a destination identity `(outputToken, destinationChainId, recipient)`, the canonical tree contains:

- One **deposit leaf per `(sourceChain × inputToken × bridge)` tuple**, where the cross-product is constrained by:
  - The set of source chains the policy supports.
  - The set of input tokens the policy supports for this `outputToken` (same-asset and the stable allowlist).
  - The set of bridges available for each `(sourceChain, inputToken)` pair (SpokePool always; CCTP only for USDC routes; OFT only for OFT-supported tokens).
- One **withdraw leaf per source chain** with the same `(admin, user)`. Replicated per chain so the `block.chainid` binding holds; each chain's `WithdrawImplementation` leaf encodes that chain's `block.chainid` implicitly via the dispatcher.

Each leaf carries the full `params` struct including the bridge-specific configuration (fee caps, exchange rate, slippage, action data, `maxExecutionFeeBps`, etc.). All execution-time-variable values (amounts, deadlines, the dynamic execution fee) live in `submitterData`, not `params`.

Tree size grows linearly in `sourceChains × inputTokens × bridges`. For a representative policy with 6 source chains × 4 input tokens × 2 bridges plus 6 withdraw leaves, the tree contains 30 deposit leaves + 6 withdraw leaves = 36 leaves, padded to 64 (proof depth 6, proofs are 192 bytes).

## Supported Input Set

For a given `outputToken`, the supported input set is:

- **Same-asset:** the single token equal to `outputToken`. For example, an address whose `outputToken = WETH` accepts WETH (and equivalently `NATIVE_ASSET` on chains where the same identity is honored).
- **Stable allowlist:** if `outputToken` is in the maintained stablecoin allowlist, all other stables in the allowlist are also supported as inputs.

The relayer is responsible for absorbing the bps-level price difference between stablecoins as part of the relayer fee. The `stableExchangeRate` field in `SpokePoolDepositParams` is committed to in the leaf and is used to convert the output amount into input units for the fee-cap check. For same-asset routes `stableExchangeRate = 1e18`; for stable-to-stable routes it is set to the policy-defined nominal rate (typically 1e18 with the fee cap absorbing realized slippage).

The fee cap (`maxFeeFixed + maxFeeBps × inputAmount`) bounds total realized loss to the user. If the realized stable spread plus fees exceeds the cap, the deposit reverts and the funds remain at the clone, available for retry or withdraw.

For CCTP, only USDC routes are emitted because CCTP exclusively bridges USDC. For OFT, only the specific OFT-token routes the LayerZero deployment supports are emitted.

## Unsupported Input Handling

Tokens delivered to a clone that are not in any of its leaves are not bridgeable through this address. The `WithdrawImplementation` leaf provides the recovery path:

1. The clone's tree includes a `WithdrawImplementation` leaf with `WithdrawParams{admin, user}`.
2. Either `admin` or `user` can call `clone.execute(WithdrawImplementation, params, abi.encode(token, to, amount), proof)` to sweep any token (or ETH) from the clone.
3. The `admin` is `AdminWithdrawManager`, which supports two paths:
   - **Direct withdraw:** a trusted `directWithdrawer` (e.g. a refund bot) sweeps to an arbitrary recipient. Used for automated refunds.
   - **Signed withdraw to user:** anyone can trigger a sweep to the `user` address committed in the leaf, given a valid EIP-712 signature from a designated signer. Permissionless refund path.

The recommended SDK behavior is:

- The SDK indexes balances at clone addresses.
- For each balance, if the token is in the supported input set, surface it to the relayer set for execution.
- If the token is not in the supported input set, surface it to the refund bot, which signs a `SignedWithdraw` and triggers `signedWithdrawToUser`.

The user always has the unilateral escape hatch via the `user` authorization in the withdraw leaf — they do not need the bot to recover funds.

## Cross-Chain Consistency Mechanics

Two factors make addresses identical across chains:

1. **Identical clone initCode.** The CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`, available on every EVM chain), the factory address (deterministic from the deployer + salt + factory initCode), the salt, and the immutable arg (the merkle root) are all identical across chains. Resulting CREATE2 address is identical.

2. **`block.chainid` in the leaf preimage at execute time.** The same merkle root can authorize chain-specific `(implementation, params)` tuples because the dispatcher folds `block.chainid` in at proof verification. Off-chain, the canonical tree is constructed by enumerating the cross-product across all supported source chains; on-chain, only the leaf matching the current `block.chainid` will verify.

Per-chain bridge implementation addresses (which differ across chains because their constructor immutables differ) are committed in each leaf's `implementation` field. The off-chain tree builder uses the per-chain deployed-addresses lookup; on-chain, only the leaf containing the current chain's implementation address will verify.

## Dynamic Execution Fees

The fee paid to the relayer at execute time is supplied by the relayer (not baked into `params`) and authorized by an EIP-712 signature from a designated signer. This lets the fee track gas prices and relayer competition without requiring users to over-quote at address-derivation time.

### SpokePool

The SpokePool implementation has always had a local signer for execution parameters. The signer's typehash is extended to include `executionFee`:

```
ExecuteDeposit(
    bytes32 paramsHash,
    uint256 inputAmount,
    uint256 outputAmount,
    uint256 executionFee,
    bytes32 exclusiveRelayer,
    uint32 exclusivityDeadline,
    uint32 quoteTimestamp,
    uint32 fillDeadline,
    uint32 signatureDeadline
)
```

`paramsHash = keccak256(params)` binds the signature to the leaf so a signature issued for one leaf cannot be replayed against a different leaf in the same clone. The existing fee cap (`maxFeeFixed + maxFeeBps × inputAmount`) continues to bound `relayerFee + executionFee`, so a compromised signer cannot extract more than the user-committed fee headroom.

### CCTP and OFT

CCTP and OFT delegate route authorization to `SponsoredCCTPSrcPeriphery` / `SponsoredOFTSrcPeriphery`. Their quote signatures do not include the execution fee, so a local signer is added to each implementation to authorize the runtime fee.

```
// CCTP
ExecuteCCTP(bytes32 paramsHash, uint256 amount, uint256 executionFee, uint256 executionFeeDeadline)

// OFT
ExecuteOFT(bytes32 paramsHash, uint256 amount, uint256 executionFee, uint256 executionFeeDeadline)
```

Two signatures are verified per CCTP / OFT execute: the periphery's quote signature (route + amount) and the local signature (fee). A `maxExecutionFeeBps` field is added to each implementation's `params` struct and enforced on-chain: `executionFee ≤ maxExecutionFeeBps × amount / 10_000`. This caps the blast radius of a local-signer compromise at a user-committed percentage of the deposit.

## Route Signature Binding (SpokePool)

Pre-V2, the SpokePool implementation relied on the rule "no duplicate implementation type per clone" to prevent signature confusion between leaves. V2's any-input-token cross-product produces multiple SpokePool leaves per clone, so this rule cannot hold. The fix is the `paramsHash` binding in the EIP-712 typehash above: the signer attests to a specific leaf's route, so a signature issued for leaf A cannot be replayed by submitting it with leaf B's params. CCTP and OFT are unaffected because their periphery-side signature already covers the full route.

## System Evolution

Addresses are frozen artifacts. Once an address is derived, its merkle tree, the implementation addresses it points to, and the implementation bytecode are immutable. The evolution model:

- **New source chain:** add the chain to the canonical tree's cross-product. New trees produce new addresses. Existing addresses do not gain support for the new chain; users wanting that support regenerate.
- **New destination chain:** introduce as a new `(outputToken, destinationChainId, recipient)` identity. Has its own address space.
- **New input token:** add to the supported-input set in the policy. New trees produce new addresses.
- **New bridge integration:** deploy the new bridge implementation contract, then include it in the cross-product. New trees, new addresses.
- **Bug fixes in implementations:** deploy a new implementation, update the tree generation to point at the new implementation address. New trees, new addresses. Existing addresses continue using the old (buggy) implementations.

Migration of an existing address's funds to a new-version address is performed by the address owner via the withdraw leaf. The flow:

1. New version of the system is deployed (new factory, new implementations).
2. SDK generates the new-version address for the same `(outputToken, destinationChainId, recipient)` policy.
3. The address owner (via `user` authorization or via `AdminWithdrawManager.signedWithdrawToUser`) sweeps the old clone's balance to themselves.
4. The owner redeposits to the new-version address.

This is a deliberate constraint: the immutability of an address's behavior is what makes the address safe to use as a long-lived identity. No upgrade authority can retroactively change what an address does with the user's funds.

## Worked Example

Destination identity:

- `dstChain` = HyperEVM (`destinationChainId = 999`)
- `outputToken` = USDC on HyperEVM
- `recipient` = `0xRECIP`

Withdraw configuration:

- `admin` = `AdminWithdrawManager` (deterministic same address on every EVM chain)
- `user` = `0xUSER`

Supported source chains: Ethereum (1), Arbitrum (42161), Base (8453), Optimism (10), Polygon (137), Avalanche (43114).

Supported input tokens: USDC, USDT, USDe, USDG (all stables; same-asset and stable-to-stable to USDC).

Bridges per `(sourceChain, inputToken)`:

- SpokePool: all 4 input tokens (relayer fills with USDC at destination, absorbing the stable spread within the fee cap).
- CCTP: USDC only.

Per chain: 4 SpokePool leaves + 1 CCTP leaf + 1 withdraw leaf = 6 leaves. Total: 6 × 6 = 36 leaves, padded to 64.

Each leaf's preimage:

```
keccak256(bytes.concat(keccak256(abi.encode(chainId, implementation, keccak256(params)))))
```

The route-defining slice of each leaf:

| #     | chainId (src) | Bridge    | Input token         | Destination encoding     | Output token | Recipient                    |
| ----- | ------------- | --------- | ------------------- | ------------------------ | ------------ | ---------------------------- |
| 0     | 1             | SpokePool | USDC_eth            | `destinationChainId=999` | USDC_hyper   | `0xRECIP`                    |
| 1     | 1             | SpokePool | USDT_eth            | `destinationChainId=999` | USDC_hyper   | `0xRECIP`                    |
| 2     | 1             | SpokePool | USDe_eth            | `destinationChainId=999` | USDC_hyper   | `0xRECIP`                    |
| 3     | 1             | SpokePool | USDG_eth            | `destinationChainId=999` | USDC_hyper   | `0xRECIP`                    |
| 4     | 1             | CCTP      | USDC_eth            | `destinationDomain=13`   | USDC_hyper   | `0xRECIP`                    |
| 5–9   | 42161         | …         | … (Arbitrum slice)  | …                        | …            | …                            |
| 10–14 | 8453          | …         | … (Base slice)      | …                        | …            | …                            |
| 15–19 | 10            | …         | … (Optimism slice)  | …                        | …            | …                            |
| 20–24 | 137           | …         | … (Polygon slice)   | …                        | …            | …                            |
| 25–29 | 43114         | …         | … (Avalanche slice) | …                        | …            | …                            |
| 30–35 | per chain     | Withdraw  | —                   | —                        | —            | `admin=0xADMIN, user=0xUSER` |
| 36–63 | —             | —         | padding             | —                        | —            | —                            |

A representative full `params` struct for leaf #1 (Ethereum, SpokePool, USDT input):

```solidity
SpokePoolDepositParams({
    destinationChainId: 999,
    inputToken:         bytes32(uint256(uint160(USDT_eth))),
    outputToken:        bytes32(uint256(uint160(USDC_hyper))),
    recipient:          bytes32(uint256(uint160(0xRECIP))),
    message:            "",
    stableExchangeRate: 1e18,           // USDT ≈ USDC for fee-cap arithmetic
    maxFeeFixed:        2_000_000,      // 2 USDT (6 decimals) fixed-fee headroom
    maxFeeBps:          20              // 0.20% variable-fee cap
})
```

`executionFee` is not in `params` — it is supplied at execute time in `SpokePoolSubmitterData` and authorized by the SpokePool implementation's signer over an EIP-712 message that includes the leaf's `paramsHash`.

A representative full `params` struct for leaf #4 (Ethereum, CCTP, USDC input):

```solidity
CCTPDepositParams({
    destinationDomain:    13,                              // HyperEVM CCTP domain (illustrative)
    mintRecipient:        bytes32(uint256(uint160(DstPeriphery_hyper))),
    burnToken:            bytes32(uint256(uint160(USDC_eth))),
    destinationCaller:    bytes32(uint256(uint160(permissionedBot))),
    cctpMaxFeeBps:        10,                              // 0.10% CCTP fee cap
    minFinalityThreshold: 1000,
    maxBpsToSponsor:      50,                              // relayer may sponsor up to 0.50%
    maxUserSlippageBps:   30,                              // 0.30% destination slippage
    finalRecipient:       bytes32(uint256(uint160(0xRECIP))),
    finalToken:           bytes32(uint256(uint160(USDC_hyper))),
    destinationDex:       0,
    accountCreationMode:  0,
    executionMode:        0,
    actionData:           "",
    maxExecutionFeeBps:   50                               // 0.50% cap on the dynamic executionFee
})
```

A representative `WithdrawParams` for leaf #30 (Ethereum, Withdraw):

```solidity
WithdrawParams({ admin: 0xADMIN, user: 0xUSER })
```

### Execution Flow

A user funds the predicted clone address on Arbitrum with 100 USDT. A relayer detects the balance:

1. Look up the address record → policy + destination identity.
2. Regenerate the canonical tree.
3. Identify the matching leaf: Arbitrum + SpokePool + USDT.
4. Build a 6-hash merkle proof for that leaf.
5. Obtain a signer EIP-712 signature over `(paramsHash, inputAmount=100e6, outputAmount, executionFee=500_000, exclusiveRelayer, exclusivityDeadline, quoteTimestamp, fillDeadline, signatureDeadline)`.
6. Call `factory.deployIfNeededAndExecute(SpokePoolImpl_arb, merkleRoot, salt, executeCalldata)` with `executeCalldata = abi.encodeCall(CounterfactualDeposit.execute, (SpokePoolImpl_arb, params, submitterData, proof))`.

On-chain:

```solidity
bytes32 leaf = keccak256(
    bytes.concat(
        keccak256(abi.encode(
            block.chainid,             // 42161 — forced by dispatcher, not caller-supplied
            implementation,            // SpokePoolImpl_arb
            keccak256(params)          // leaf #6's full params hash
        ))
    )
);
require(MerkleProof.verify(proof, merkleRoot, leaf));
implementation.delegatecall(abi.encodeCall(...));
```

Defenses asserted by the above:

- **Cross-chain replay** — leaf #6's proof on Base fails: `block.chainid` would be 8453, the rebuilt leaf would differ, the proof would not verify.
- **Implementation substitution** — substituting `SpokePoolImpl_eth` while proving leaf #6 fails: `implementation` differs, leaf hash differs, proof fails.
- **Route swap via signature confusion** — supplying USDC-route params (leaf #5) but a signature signed for the USDT route (leaf #6) fails: the `paramsHash` in the typehash binds the signature to a specific leaf.

## Caveats

1. **Adding a new source or destination chain requires a new address.** The canonical tree's cross-product is fixed at address-derivation time; expanding it changes the root and changes the address. Users wanting future-chain support must regenerate.
2. **Tron is a carveout.** Tron's TVM uses `0x41` as the CREATE2 prefix instead of `0xff`. The same merkle root produces a different address on Tron. `CounterfactualDepositFactoryTron` overrides the prediction logic to use the correct prefix. Same address across EVM chains; different address on Tron.
3. **Per-bridge token reach is bounded.** CCTP can only bridge USDC. OFT can only bridge specific OFT tokens. SpokePool can take any input token Across has relayer liquidity for. The "any supported input" guarantee is only as broad as the SDK actually emits leaves for.
4. **All chain-specific implementations must be deployed before address generation.** Today's deployment flow already lands per-chain implementations deterministically via the deterministic-deployment proxy; nothing new operationally.
5. **EIP-712 cross-chain replay is not a concern.** OpenZeppelin's `_hashTypedDataV4` mixes `block.chainid` into the domain separator at call time, so a SpokePool / CCTP / OFT local signature for chain A does not validate on chain B regardless of clone-address sameness.
6. **Stable spread is absorbed by the relayer within the fee cap.** Stable-to-stable routes assume the realized spread plus fees fits within `maxFeeFixed + maxFeeBps × inputAmount`. If the spread blows out, deposits revert and funds wait at the clone for retry or withdraw — they are never executed at unfavorable terms.

## Backend / SDK / API Implications

This is where most of the non-contract work lands.

### Address Derivation

- **Cross-product enumeration.** The SDK enumerates `(sourceChain, inputToken, bridge)` tuples and constructs the canonical tree. For each tuple it must resolve the chain-correct implementation address and chain-correct token address.
- **Implementation address registry.** The SDK maintains a per-chain mapping of deployed `CounterfactualDepositSpokePool` / `CounterfactualDepositCCTP` / `CounterfactualDepositOFT` addresses, pinned to a system version. The source of truth is `broadcast/deployed-addresses.json`.
- **Token address registry.** Per-chain token addresses for USDC, USDT, USDe, USDG, and any other allowlisted stables. Accuracy is load-bearing — a wrong token address produces an address whose tree commits to the wrong token.
- **Destination-identifier mapping.** Per-bridge: `dstChain → destinationChainId` (SpokePool), `dstChain → destinationDomain` (CCTP), `dstChain → dstEid` (OFT). The SDK owns this mapping. Errors produce a tree with a leaf that bridges to the wrong destination — because destination is bound into the address via the merkle root, users / auditors can detect this by independently reconstructing the tree.
- **Failure mode.** A wrong implementation address, token address, or destination-identifier in the SDK produces an address whose CREATE2 derivation differs from the canonical. Funds sent by users to the canonical address are not affected; the SDK-fabricated address is simply orphaned.

### Quoting

- **Per-leaf quotes.** A single address has multiple possible routes. The quoting service decides which leaves to advertise and prices each independently. The UI surfaces the user-preferred route; the relayer can execute any leaf the funded token matches.
- **Quote signing for SpokePool.** Each quote produces an EIP-712 signature bound to the specific leaf via `paramsHash`. CCTP / OFT quotes are unchanged from V1 (still signed by the periphery quote signer) plus a new local-fee signature.
- **Tree exposure for transparency.** Users / integrators verify the destination invariant by reconstructing the tree from declared policy and confirming the CREATE2 address matches. The API should expose the canonical leaf list (or the policy that derives it) for any clone address.

### Relayer Infrastructure

- **Multi-chain, multi-token watching.** A single address can receive funds on any supported source chain in any supported input token. Relayers watch the same address on every supported chain across the configured input-token set.
- **Leaf-selection logic.** When a clone holds multiple input tokens simultaneously, relayers select one or more leaves and execute sequentially.
- **Profitability across leaves.** For USDC routes, both SpokePool and CCTP leaves are available; relayers pick whichever is more profitable.
- **Funding-detection latency.** Per-address fan-out scales as `chains × tokens`. RPC / mempool / index strategy must scale accordingly for high-traffic addresses.

### Refund Bot

- **Token classification.** For each balance detected at a clone, the bot classifies as supported (let the relayer handle it) or unsupported (refund).
- **Signed refunds.** For unsupported tokens, the bot constructs a `SignedWithdraw` EIP-712 message via `AdminWithdrawManager.signer` and triggers `signedWithdrawToUser`, which sweeps the token to the `user` address committed in the withdraw leaf.
- **User self-recovery.** If the bot is unavailable, the user can call `clone.execute(WithdrawImplementation, ...)` directly using their own private key.

### Indexer / Analytics

- **Address ↔ deposit-source mapping is no longer 1:1 with a single event.** Per-execute, the deposit event identifies the source chain and input token. The address itself is shared across chains, so cross-chain aggregation is required for any "where did this user deposit?" question.
- **Versioning.** Indexers must track the system version each address was derived against, since address generation is non-portable across versions.

### Migration

- **Existing V1 addresses do not migrate to V2 in place.** They keep working against V1 contracts. V2 deploys at fresh CREATE2 addresses (new factory, new implementations). The SDK switches new address generation to V2.
- **No upgrade path for live V1 clones.** EIP-1167 proxies are not upgradeable. A user with a populated V1 tree keeps that tree; they obtain a new address if they want V2 properties.
- **Forward migration.** Users with funds at a V1 address use the V1 withdraw leaf to sweep funds to themselves, then redeposit to their V2 address.

## Open Product Questions

- **Default input-token set per `(dstChain, outputToken)`.** What's in the cross-product at launch? Affects tree size, relayer coverage, and the marketing claim. Stable allowlist composition and source-chain set need product alignment.
- **Stronger upgrade story.** The current evolution model freezes addresses against the version they were derived against. If a stronger property is needed (e.g. "all existing addresses inherit a critical bug fix"), the design would need to change — likely toward an upgradeable dispatcher or a signer-attested root extension. Out of scope for V2.
- **Per-chain extension leaves.** An alternative to "regenerate address for new chains" would be a signed-root-update mechanism: the SDK could publish a signature authorizing additional leaves for an existing address. Breaks the strict CREATE2 → merkle root → leaf-set binding; defer unless the regeneration cost becomes a real friction.
