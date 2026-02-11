# Counterfactual Deposit Addresses

Gas-optimized system for creating persistent, reusable deposit addresses via CREATE2.

## Architecture

**Three-contract system:**

- `CounterfactualDeposit` - Minimal proxy with route parameters as immutables
- `CounterfactualDepositExecutor` - Singleton implementation called via delegatecall
- `CounterfactualDepositFactory` - CREATE2 factory and signature verification

## Key Design Decisions

### 1. Immutable Distribution (Gas Optimization)

**Factory and SpokePool are immutable in the Executor, not the proxy.**

Why: These values are identical across all deposit addresses on a chain. Storing them in each proxy wastes ~64 bytes per deployment (~12,800 gas).

The proxy only stores an immutable reference to the executor contract itself, then delegates all calls directly. This avoids:

- Storing factory address in proxy (not needed—executor has it)
- Storing spokePool address in proxy (not needed—executor has it)
- Querying factory.executor() on every call (~2,600 gas saved per execution)

When delegatecall executes:

- Storage context = proxy (token balances, message)
- Immutables = executor's bytecode (factory, spokePool) + proxy's bytecode (executor reference, route params)

**Savings:** ~9k gas per address deployment + ~2,600 gas per execution.

### 2. No Nonce Tracking (Quote Reusability)

**Quotes can be reused multiple times—there's no nonce mapping.**

Why: The signature protects the _user_ from unauthorized deposits, not the relayer from quote reuse. If a valid quote exists for an address with sufficient balance, executing it multiple times is acceptable behavior.

Protection comes from `quote.depositAddress` binding—a quote signed for address A cannot be used on address B.

**Trade-off:** Same quote can execute repeatedly vs. preventing any replay.

### 3. Custom Calldata Passing

**The proxy appends ABI-encoded route parameters to the original calldata before delegatecall.**

Why: Immutables aren't accessible in delegatecall context through normal means. The executor needs route parameters (inputToken, outputToken, etc.) that are immutable in the proxy.

Format: `[original calldata] [ABI-encoded RouteParams] [uint256 original size]`

The executor reads the size marker from the end, then extracts route params using assembly.

### 4. Message Storage vs. Immutables

**Message is stored in storage, not as an immutable, with a `hasMessage` bool optimization.**

Why: `bytes` cannot be immutable (Solidity limitation). Storing in storage allows variable-length messages.

Optimization: `hasMessage` bool immutable avoids storage read in the common case (empty message). The fallback only reads `message` from storage if `hasMessage == true`.

### 5. Fee Protection Mechanism

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

### 6. Address Reusability

**The same counterfactual address can receive and execute multiple deposits over time.**

Why: Enables persistent "deposit addresses" that users can save, share, and reuse—like a traditional address.

The factory's `deployAndExecute()` uses try/catch to handle already-deployed addresses gracefully, while `executeOnExisting()` skips deployment entirely for subsequent deposits.

### 7. Depositor is the Contract

**The deposit is made with `depositor = address(this)` (the counterfactual contract), not `msg.sender`.**

Why: If a deposit needs to be refunded by the HubPool, the refund will be sent to the counterfactual address (where admin can recover it), not to the caller (who may be a relayer).

This ensures users don't lose funds in edge cases.

### 8. EIP-712 Structured Signatures

**Quotes are signed using EIP-712 typed structured data via OpenZeppelin's battle-tested EIP712 library.**

Why: EIP-712 provides superior UX and security:

**User Experience**: When signing in wallets like MetaMask, users see:

```
Sign Deposit Quote:
  Deposit Address: 0x1234...
  Input Amount: 100 USDC
  Output Amount: 99 USDC
  Deadline: Jan 15, 2025 12:00 PM
```

Instead of an opaque hash:

```
Sign message:
  0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb7
```

**Security Benefits**:

- Domain separation prevents signature replay across different contracts or chains
- Typed data makes phishing attacks harder (users can verify what they're signing)
- Industry standard adopted by major protocols (Uniswap, OpenSea, etc.)

**Implementation**:

```solidity
// Factory inherits from OpenZeppelin's EIP712
contract CounterfactualDepositFactory is ICounterfactualDepositFactory, EIP712 {
    constructor(...) EIP712("Across Counterfactual Deposit", "1") {
        // ...
    }

    function verifyQuote(...) public view returns (bool) {
        bytes32 structHash = keccak256(abi.encode(DEPOSIT_QUOTE_TYPEHASH, ...));
        bytes32 digest = _hashTypedDataV4(structHash); // OZ helper
        address recoveredSigner = ECDSA.recover(digest, signature);
        return recoveredSigner == quoteSigner;
    }
}
```

## Usage Pattern

**Initial setup:**

```solidity
address predictedAddress = factory.predictDepositAddress(
    inputToken, outputToken, destinationChainId,
    recipient, message, maxGasFee, maxCapitalFee, salt
);
// Share predictedAddress with user
```

**First deposit (deploys + executes):**

```solidity
factory.deployAndExecute(
    routeParams..., salt, signedQuote, signature
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

## Gas Costs

- **Deployment**: ~33-35k gas (minimal proxy with executor reference + route params)
- **First deposit**: ~180-230k gas (deploy + execute + SpokePool deposit)
- **Subsequent deposits**: ~107-157k gas (execute + SpokePool deposit, no deployment)

The optimization of storing only the executor reference (instead of factory + spokePool) saves:

- ~9k gas per deployment
- ~2.6k gas per execution (no external call to factory.executor())
