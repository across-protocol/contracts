# Counterfactual Deposit Addresses

Gas-optimized system for creating persistent, reusable deposit addresses via CREATE2.

## Architecture

**Two-contract system using OpenZeppelin EIP-1167 Clones with Immutable Args:**

- `CounterfactualDepositExecutor` - Implementation contract; the factory deploys EIP-1167 clones of this with route params appended to bytecode
- `CounterfactualDepositFactory` - CREATE2 factory (via `Clones.cloneDeterministicWithImmutableArgs`) and EIP-712 signature verification

Each deposit address is a minimal EIP-1167 proxy pointing to the executor, with ABI-encoded route parameters appended to the clone bytecode. The executor reads them via `Clones.fetchCloneArgs(address(this))`.

## Key Design Decisions

### 1. Immutable Distribution (Gas Optimization)

**Factory and SpokePool are immutable in the Executor, not the clone.**

Why: These values are identical across all deposit addresses on a chain. Storing them in each clone wastes gas.

The clone only stores route-specific parameters (inputToken, outputToken, etc.) as immutable args in bytecode. Chain-wide constants (factory, spokePool) live in the executor's bytecode and are accessible directly since EIP-1167 proxies use delegatecall.

### 2. No Nonce Tracking (Quote Reusability)

**Quotes can be reused multiple times—there's no nonce mapping.**

Why: The signature protects the _user_ from unauthorized deposits, not the relayer from quote reuse. If a valid quote exists for an address with sufficient balance, executing it multiple times is acceptable behavior.

Protection comes from `quote.depositAddress` binding—a quote signed for address A cannot be used on address B.

**Trade-off:** Same quote can execute repeatedly vs. preventing any replay.

### 3. OZ Clones with Immutable Args

**Route parameters are appended to clone bytecode via `Clones.cloneDeterministicWithImmutableArgs`.**

The executor reads them with `Clones.fetchCloneArgs(address(this))` (uses EXTCODECOPY). This replaces a custom proxy + assembly approach with a battle-tested OZ library.

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

**The same counterfactual address can receive and execute multiple deposits over time.**

Why: Enables persistent "deposit addresses" that users can save, share, and reuse—like a traditional address.

The factory's `deployAndExecute()` uses try/catch to handle already-deployed addresses gracefully, while `executeOnExisting()` skips deployment entirely for subsequent deposits.

### 6. Depositor is the Contract

**The deposit is made with `depositor = address(this)` (the counterfactual contract), not `msg.sender`.**

Why: If a deposit needs to be refunded by the HubPool, the refund will be sent to the counterfactual address (where admin can recover it), not to the caller (who may be a relayer).

This ensures users don't lose funds in edge cases.

### 7. EIP-712 Structured Signatures

**Quotes are signed using EIP-712 typed structured data via OpenZeppelin's battle-tested EIP712 library.**

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
// Share predictedAddress with user
```

**First deposit (deploys + executes):**

```solidity
factory.deployAndExecute(
    executor, routeParams..., salt, signedQuote, signature
);
```

**Subsequent deposits (already deployed):**

```solidity
factory.executeOnExisting(depositAddress, signedQuote, signature);
```

## Security Model

- **Quote Signer**: Trusted address that signs quotes. Compromise allows bad quotes but fees are bounded by user-set limits.
- **Admin**: Can withdraw any tokens (for refunds/recovery). Should be a multisig.
- **User Protection**: Fee limits prevent quote signer from taking excessive fees.
- **Quote Binding**: `depositAddress` in quote prevents cross-address replay.
- **Expiration**: `quote.deadline` prevents stale quote execution.
- **EIP-712 Signatures**: Quotes are signed using EIP-712 structured data, providing:
  - Clear visibility of what's being signed in wallets
  - Domain separation (binds signatures to this contract and chain)
  - Protection against cross-contract replay attacks
