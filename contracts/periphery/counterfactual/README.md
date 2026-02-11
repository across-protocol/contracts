# Counterfactual Deposit Addresses

Gas-optimized system for creating persistent, reusable deposit addresses via deterministic CREATE2 deployment.

## Architecture

**Two-contract system using OpenZeppelin EIP-1167 Clones with Immutable Args:**

- `CounterfactualDepositExecutor` — Implementation contract. Each deposit address is an EIP-1167 minimal proxy (clone) of this contract, with route parameters appended to the clone's bytecode as immutable args.
- `CounterfactualDepositFactory` — Deploys clones deterministically via `Clones.cloneDeterministicWithImmutableArgs`, predicts addresses, and verifies EIP-712 quote signatures.

```
                          ┌─────────────────────────────────────────┐
                          │       CounterfactualDepositFactory      │
                          │  - cloneDeterministicWithImmutableArgs  │
                          │  - predictDeterministicAddress          │
                          │  - EIP-712 signature verification       │
                          └──────────┬──────────────────────────────┘
                                     │ deploys
                    ┌────────────────┼────────────────┐
                    ▼                ▼                 ▼
            ┌──────────────┐ ┌──────────────┐  ┌──────────────┐
            │  Clone 0x1…  │ │  Clone 0x2…  │  │  Clone 0x3…  │
            │  (45 bytes   │ │  (45 bytes   │  │  (45 bytes   │
            │   + args)    │ │   + args)    │  │   + args)    │
            └──────┬───────┘ └──────┬───────┘  └──────┬───────┘
                   │ delegatecall   │                  │
                   └────────────────┼──────────────────┘
                                    ▼
                    ┌───────────────────────────────┐
                    │ CounterfactualDepositExecutor  │
                    │  - executeDeposit()            │
                    │  - adminWithdraw()             │
                    │  - immutable: factory, spoke   │
                    └───────────────────────────────┘
```

When a clone receives a call, the EIP-1167 bytecode `delegatecall`s to the executor. Inside that context:

- `address(this)` = the clone's address (holds token balances, receives refunds)
- Code executing = the executor's bytecode (has `factory` and `spokePool` immutables)
- Route params = read from the clone's bytecode via `Clones.fetchCloneArgs(address(this))`

## Key Design Decisions

### 1. Immutable Distribution (Gas Optimization)

**Factory and SpokePool are immutable in the Executor, not the clone.**

Why: These values are identical across all deposit addresses on a chain. Storing them in each clone wastes gas.

The clone only stores route-specific parameters (inputToken, outputToken, etc.) as immutable args in bytecode. Chain-wide constants (factory, spokePool) live in the executor's bytecode and are accessible directly since EIP-1167 proxies use delegatecall.

### 2. No Nonce Tracking (Quote Reusability)

**Quotes can be reused multiple times — there's no nonce mapping.**

Why: The signature protects the _user_ from unauthorized deposits, not the relayer from quote reuse. If a valid quote exists for an address with sufficient balance, executing it multiple times is acceptable behavior.

Protection comes from `quote.depositAddress` binding — a quote signed for address A cannot be used on address B.

**Trade-off:** Same quote can execute repeatedly vs. preventing any replay.

### 3. OZ Clones with Immutable Args

**Route parameters are baked into each clone's bytecode rather than written to storage.**

[EIP-1167](https://eips.ethereum.org/EIPS/eip-1167) defines a minimal proxy contract — 45 bytes of bytecode that forwards every call to a fixed implementation via `delegatecall`. OpenZeppelin's `Clones.cloneDeterministicWithImmutableArgs` extends this by appending arbitrary bytes after the proxy bytecode. These bytes become part of the deployed contract's code and can be read back with `Clones.fetchCloneArgs(address(this))`, which uses `EXTCODECOPY` to copy the appended region.

**How it's used here:** The factory ABI-encodes the route parameters (inputToken, outputToken, destinationChainId, recipient, maxGasFee, maxCapitalFee, message) and passes them as the immutable args when deploying a clone. When `executeDeposit()` is called on a clone, the executor reads the args back via `fetchCloneArgs` and decodes them.

**Why not normal storage?** Storage-based alternatives are significantly more expensive:

- **SSTORE (cold)** costs 22,100 gas per slot on first write. Route params span 7+ slots, so deploying a storage-based proxy would cost ~155k+ gas just for the writes — compared to the clone's total deployment cost of ~40k gas.
- **SLOAD (cold)** costs 2,100 gas per slot on first read within a transaction. Reading 7 slots costs ~14,700 gas. `EXTCODECOPY` reads the entire args blob in a single operation for ~2,600 gas (base) + minimal per-word cost.
- Clone deployment uses `CREATE2` with a tiny initcode (45 bytes + args), so there's no constructor execution overhead.

The pattern also eliminates the need for any custom proxy or assembly — the OZ library handles proxy deployment, deterministic addressing, and arg retrieval.

### 4. Fee Protection Mechanism

**Users set two fee limits: `maxGasFee` (absolute wei) and `maxCapitalFee` (relative bps). Total fee must not exceed their sum.**

Why: Quotes are signed by a permissioned address with variable `outputAmount`. Without limits, a compromised signer could drain deposits via excessive fees.

The executor validates:

```solidity
uint256 actualFee = inputAmount - outputAmount;
uint256 maxAllowedFee = maxGasFee + (inputAmount * maxCapitalFee / 10000);
require(actualFee <= maxAllowedFee);
```

**Example:** User deposits 1000 USDC with `maxGasFee = 5 USDC` and `maxCapitalFee = 50 bps` (0.5%).

- Max allowed fee = 5 USDC + (1000 \* 0.005) = 5 + 5 = 10 USDC
- A quote with `outputAmount = 991 USDC` (9 USDC fee) would pass
- A quote with `outputAmount = 989 USDC` (11 USDC fee) would be rejected

### 5. Address Reusability

**The same clone proxy can receive and execute multiple deposits over time.**

Why: Enables persistent "deposit addresses" that users can save, share, and reuse — like a traditional address.

The factory's `deployAndExecute()` uses try/catch to handle already-deployed clones gracefully, while `executeOnExisting()` skips deployment entirely for subsequent deposits.

### 6. Depositor is the Clone Proxy

**The deposit is made with `depositor = address(this)` (the clone proxy), not `msg.sender`.**

Why: If a deposit needs to be refunded by the HubPool, the refund will be sent to the clone proxy address (where admin can recover it via `adminWithdraw`), not to the caller (who may be a relayer).

This ensures users don't lose funds in edge cases.

### 7. EIP-712 Structured Signatures

**Quotes are signed using EIP-712 typed structured data via OpenZeppelin's EIP712 library.**

Why: EIP-712 provides superior UX and security:

- Domain separation prevents signature replay across different contracts or chains
- Typed data makes phishing attacks harder (users can verify what they're signing)
- Industry standard adopted by major protocols (Uniswap, OpenSea, etc.)

## Usage Pattern

**Initial setup:**

```solidity
address predictedAddress = factory.predictDepositAddress(
    executor, inputToken, outputToken, destinationChainId,
    recipient, message, maxGasFee, maxCapitalFee, salt
);
// Share predictedAddress with user — tokens sent here before deployment are safe
```

**First deposit (deploys clone + executes):**

```solidity
factory.deployAndExecute(
    executor, routeParams..., salt, signedQuote, signature
);
```

**Subsequent deposits (clone already deployed):**

```solidity
factory.executeOnExisting(depositAddress, signedQuote, signature);
```

## Security Model

- **Quote Signer**: Trusted address that signs quotes. Compromise allows bad quotes but fees are bounded by user-set limits.
- **Admin**: Can withdraw any tokens from any clone via `adminWithdraw` (for refunds/recovery). Should be a multisig.
- **User Protection**: Fee limits (maxGasFee + maxCapitalFee) prevent quote signer from taking excessive fees.
- **Quote Binding**: `depositAddress` in quote prevents cross-address replay.
- **Expiration**: `quote.deadline` prevents stale quote execution.
- **EIP-712 Signatures**: Domain separation binds signatures to this factory contract and chain, preventing cross-contract replay.
