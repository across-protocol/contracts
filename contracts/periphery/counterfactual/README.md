# Counterfactual Deposit Addresses

Gas-optimized system for creating persistent, reusable deposit addresses via deterministic CREATE2 deployment. Supports multiple bridge types: **CCTP**, **OFT** (LayerZero), and **SpokePool** (Across).

## Architecture

**Generic factory + bridge-specific implementations using OpenZeppelin EIP-1167 Clones with Immutable Args:**

- `CounterfactualDepositFactory` — Bridge-agnostic factory. Deploys clones deterministically via `Clones.cloneDeterministicWithImmutableArgs`, predicts addresses, and forwards raw calldata to clones. Takes `bytes memory encodedParams` — it never reads struct fields, only hashes them.
- `CounterfactualDepositBase` — Abstract base contract inherited by all implementations. Provides shared logic: params hash verification (`_verifyParamsHash`), withdraw helpers (`_adminWithdraw`, `_userWithdraw`), and constants (`BPS_SCALAR`, `PRICE_SCALAR`).
- `CounterfactualDepositCCTP` — Implementation for deposits via SponsoredCCTP. Builds a `SponsoredCCTPQuote` and calls `SponsoredCCTPSrcPeriphery.depositForBurn()`.
- `CounterfactualDepositOFT` — Implementation for deposits via SponsoredOFT (LayerZero). Builds a `Quote` and calls `SponsoredOFTSrcPeriphery.deposit()`. Supports `msg.value` forwarding for LZ native messaging fees.
- `CounterfactualDepositSpokePool` — Implementation for deposits via Across SpokePool. Verifies EIP-712 signatures itself (since it calls `SpokePool.deposit()` directly) and enforces relayer fee bounds.

```
                    CounterfactualDepositFactory (generic)
                    - deploy(implementation, encodedParams, salt)
                    - predictDepositAddress(implementation, encodedParams, salt)
                    - deployAndExecute(implementation, encodedParams, salt, executeCalldata)
                              |
             +----------------+----------------+
             |                |                |
             v                v                v
     CCTP Deposit       OFT Deposit      SpokePool Deposit
     -> SponsoredCCTP   -> SponsoredOFT  -> SpokePool.deposit()
       SrcPeriphery       SrcPeriphery
```

When a clone receives a call, the EIP-1167 bytecode `delegatecall`s to the implementation. Inside that context:

- `address(this)` = the clone's address (holds token balances)
- Code executing = the implementation's bytecode (has implementation-specific immutables like `srcPeriphery`, `spokePool`, etc.)
- Route params hash = read from the clone's bytecode via `Clones.fetchCloneArgs(address(this))`, verified against caller-supplied params

## CCTP Implementation (`CounterfactualDepositCCTP`)

| Variable                | Source                | Description                                                             |
| ----------------------- | --------------------- | ----------------------------------------------------------------------- |
| `srcPeriphery`          | Constructor immutable | SponsoredCCTPSrcPeriphery contract address                              |
| `sourceDomain`          | Constructor immutable | CCTP source domain ID for this chain                                    |
| `destinationDomain`     | Route immutable       | CCTP destination domain (e.g. 3 for Hyperliquid)                        |
| `mintRecipient`         | Route immutable       | DstPeriphery handler contract on destination                            |
| `burnToken`             | Route immutable       | Token to burn (e.g. USDC address as bytes32)                            |
| `destinationCaller`     | Route immutable       | Permissioned bot that calls `receiveMessage` on destination             |
| `cctpMaxFeeBps`         | Route immutable       | Max CCTP fee in bps (computed to `maxFee` at execution time)            |
| `executionFee`          | Route immutable       | Fixed fee (in burnToken units) paid to relayer                          |
| `minFinalityThreshold`  | Route immutable       | Minimum finality before CCTP attestation                                |
| `maxBpsToSponsor`       | Route immutable       | Max bps of amount the relayer can sponsor                               |
| `maxUserSlippageBps`    | Route immutable       | Slippage tolerance for fees on destination                              |
| `finalRecipient`        | Route immutable       | Ultimate receiver on destination chain                                  |
| `finalToken`            | Route immutable       | Token recipient receives on destination                                 |
| `destinationDex`        | Route immutable       | DEX on HyperCore for swaps                                              |
| `accountCreationMode`   | Route immutable       | Standard (0) or FromUserFunds (1)                                       |
| `executionMode`         | Route immutable       | DirectToCore (0), ArbitraryActionsToCore (1), ArbitraryActionsToEVM (2) |
| `userWithdrawAddress`   | Route immutable       | Address authorized to call `userWithdraw()`                             |
| `adminWithdrawAddress`  | Route immutable       | Address authorized to call `adminWithdraw()`                            |
| `actionData`            | Route immutable       | Encoded action data for arbitrary execution modes                       |
| `amount`                | Argument              | Gross amount of burnToken (includes executionFee)                       |
| `executionFeeRecipient` | Argument              | Address that receives the execution fee                                 |
| `nonce`                 | Argument              | Unique nonce for SponsoredCCTP replay protection                        |
| `cctpDeadline`          | Argument              | Deadline for the SponsoredCCTP quote (validated by SrcPeriphery)        |
| `signature`             | Argument              | Signature from SponsoredCCTP quote signer                               |

Signature verification, nonce tracking, and `cctpDeadline` enforcement are handled by `SponsoredCCTPSrcPeriphery`.

## OFT Implementation (`CounterfactualDepositOFT`)

| Variable                | Source                | Description                                                             |
| ----------------------- | --------------------- | ----------------------------------------------------------------------- |
| `oftSrcPeriphery`       | Constructor immutable | SponsoredOFTSrcPeriphery contract address                               |
| `srcEid`                | Constructor immutable | OFT source endpoint ID for this chain                                   |
| `dstEid`                | Route immutable       | OFT destination endpoint ID                                             |
| `destinationHandler`    | Route immutable       | Composer contract on destination (OFT `to` param)                       |
| `token`                 | Route immutable       | Local token address (the OFT token, as bytes32)                         |
| `maxOftFeeBps`          | Route immutable       | Max OFT bridge fee in bps                                               |
| `executionFee`          | Route immutable       | Fixed fee paid to relayer                                               |
| `lzReceiveGasLimit`     | Route immutable       | Gas limit for `lzReceive` on destination                                |
| `lzComposeGasLimit`     | Route immutable       | Gas limit for `lzCompose` on destination                                |
| `maxBpsToSponsor`       | Route immutable       | Max bps of amount the relayer can sponsor                               |
| `maxUserSlippageBps`    | Route immutable       | Slippage tolerance for swap on destination                              |
| `finalRecipient`        | Route immutable       | User address on destination                                             |
| `finalToken`            | Route immutable       | Final token user receives                                               |
| `destinationDex`        | Route immutable       | Destination DEX on HyperCore                                            |
| `accountCreationMode`   | Route immutable       | Standard (0) or FromUserFunds (1)                                       |
| `executionMode`         | Route immutable       | DirectToCore (0), ArbitraryActionsToCore (1), ArbitraryActionsToEVM (2) |
| `refundRecipient`       | Route immutable       | LZ refund recipient for excess native messaging fees                    |
| `userWithdrawAddress`   | Route immutable       | Address authorized to call `userWithdraw()`                             |
| `adminWithdrawAddress`  | Route immutable       | Address authorized to call `adminWithdraw()`                            |
| `actionData`            | Route immutable       | Encoded action data for arbitrary execution modes                       |
| `amount`                | Argument              | Gross amount of token (includes executionFee)                           |
| `executionFeeRecipient` | Argument              | Address that receives the execution fee                                 |
| `nonce`                 | Argument              | Unique nonce for SponsoredOFT replay protection                         |
| `oftDeadline`           | Argument              | Deadline for the SponsoredOFT quote (validated by SrcPeriphery)         |
| `signature`             | Argument              | Signature from SponsoredOFT quote signer                                |
| `msg.value`             | Argument              | Native ETH for LayerZero messaging fees                                 |

`executeDeposit` is `payable` — `msg.value` covers LayerZero native messaging fees, forwarded to `SponsoredOFTSrcPeriphery.deposit{value: msg.value}()`. The relayer pays this and recoups via `executionFee`.

Signature verification, nonce tracking, and `oftDeadline` enforcement are handled by `SponsoredOFTSrcPeriphery`.

## SpokePool Implementation (`CounterfactualDepositSpokePool`)

| Variable                | Source                | Description                                                              |
| ----------------------- | --------------------- | ------------------------------------------------------------------------ |
| `spokePool`             | Constructor immutable | Across SpokePool contract address                                        |
| `signer`                | Constructor immutable | Address that authorizes execution parameters via EIP-712                 |
| `destinationChainId`    | Route immutable       | Across destination chain ID                                              |
| `inputToken`            | Route immutable       | Token deposited on source (as bytes32)                                   |
| `outputToken`           | Route immutable       | Token received on destination (as bytes32)                               |
| `recipient`             | Route immutable       | Recipient on destination                                                 |
| `exclusiveRelayer`      | Route immutable       | Optional exclusive relayer (bytes32(0) for none)                         |
| `price`                 | Route immutable       | inputToken per outputToken price (1e18 scaled), used for fee calculation |
| `maxFeeBps`             | Route immutable       | Max total fee (relayer + execution) in basis points                      |
| `executionFee`          | Route immutable       | Fixed fee paid to relayer calling execute                                |
| `exclusivityDeadline`   | Route immutable       | Seconds of relayer exclusivity (0 for none)                              |
| `userWithdrawAddress`   | Route immutable       | Address authorized to call `userWithdraw()`                              |
| `adminWithdrawAddress`  | Route immutable       | Address authorized to call `adminWithdraw()`                             |
| `message`               | Route immutable       | Arbitrary message forwarded to recipient                                 |
| `inputAmount`           | Argument (signed)     | Gross amount of inputToken (includes executionFee)                       |
| `outputAmount`          | Argument (signed)     | Output amount passed to SpokePool                                        |
| `executionFeeRecipient` | Argument              | Address that receives the execution fee                                  |
| `quoteTimestamp`        | Argument              | Quote timestamp from Across API (SpokePool validates recency)            |
| `fillDeadline`          | Argument (signed)     | Timestamp by which the deposit must be filled                            |
| `signature`             | Argument              | EIP-712 signature from signer over signed arguments                      |

### EIP-712 Signature Verification

Unlike CCTP/OFT (where `SrcPeriphery` verifies signatures), the SpokePool implementation verifies signatures itself since it calls `SpokePool.deposit()` directly.

- **Domain separator** uses OpenZeppelin's `EIP712` base contract with `address(this)` (the clone address) — prevents cross-clone replay
- **No nonce needed**: token balance is consumed on execution (natural replay protection), and short deadlines bound the replay window for re-funded clones
- **Typehash**: `ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,uint32 fillDeadline)`
- **Signer** is an immutable set in the implementation constructor, shared across all clones

### Fee Check

The implementation enforces that the total fee (relayer + execution) doesn't exceed `maxFeeBps`:

```
outputInInputToken = outputAmount * price / 1e18
relayerFee = depositAmount - outputInInputToken  (0 if negative)
totalFee = relayerFee + executionFee
if totalFee * 10000 > maxFeeBps * inputAmount:
    revert MaxFee
```

**Assumption:** The `price` route immutable is fixed at address-generation time, so this fee check assumes `inputToken` and `outputToken` are not volatile relative to each other (e.g. stablecoin pairs, or the same token on different chains). If the real market price drifts significantly from the committed `price`, the fee check may be too lenient or too strict.

### Depositor Field

The `depositor` parameter passed to `SpokePool.deposit()` is `address(this)` (the clone address). SpokePool refunds for expired deposits go back to the clone, where they can be re-executed or withdrawn via `userWithdraw`.

## Key Design Decisions

### 1. Generic Factory

**The factory is bridge-agnostic — it takes `bytes memory encodedParams` and `bytes calldata executeCalldata`.**

Why: Each bridge type defines its own immutables struct. The factory only hashes the encoded params (for deterministic address generation) and forwards raw calldata to clones. This means adding a new bridge type requires only a new implementation contract — no factory changes.

`deployAndExecute` is `payable` to support bridges that need `msg.value` (e.g. OFT for LayerZero fees). The factory forwards `msg.value` to the clone via low-level `call`.

### 2. No executeOnExisting

**Callers call the clone directly for subsequent deposits.**

Why: The factory's `executeOnExisting` was just a pass-through that added gas overhead. Since clones are deployed at known addresses, callers can call `executeDeposit` on the clone directly.

### 3. Immutable Distribution (Gas Optimization)

**Chain-wide constants (srcPeriphery, sourceDomain, spokePool, signer) are immutable in the Executor, not the clone.**

Why: These values are identical across all deposit addresses on a chain. Storing them in each clone wastes gas. The clone only stores route-specific parameters via a hash of the immutable args. Chain-wide constants live in the implementation's bytecode and are accessible directly since EIP-1167 proxies use delegatecall.

### 4. OZ Clones with Hash-Only Immutable Args

**Each clone stores only a keccak256 hash (32 bytes) of the route parameters, not the full params.**

[EIP-1167](https://eips.ethereum.org/EIPS/eip-1167) defines a minimal proxy contract — 45 bytes of bytecode that forwards every call to a fixed implementation via `delegatecall`. OpenZeppelin's `Clones.cloneDeterministicWithImmutableArgs` extends this by appending arbitrary bytes after the proxy bytecode.

The factory computes `keccak256(encodedParams)` and stores that 32-byte hash as the clone's sole immutable arg. At execution time, the caller passes the full params struct; the implementation hashes it and verifies against the stored hash before proceeding.

Storing full params as immutable args would cost ~595+ bytes of deployed code. With a hash, the clone stores only 77 bytes total (45-byte EIP-1167 proxy + 32-byte hash). This saves ~103k gas on deployment. The tradeoff is ~6k gas more per execution (calldata for full params + one keccak256 hash), but since each deposit address is deployed once and potentially reused many times, the net savings are significant.

### 5. Signature Verification: SpokePool vs CCTP/OFT

**CCTP and OFT implementations do NOT verify signatures — the SpokePool implementation does.**

Why: CCTP and OFT implementations forward deposits to a `SrcPeriphery` contract, which already validates the quote signature, nonce, and deadline before bridging. The implementation is just a pass-through, so adding its own signature check would be redundant.

The SpokePool implementation calls `SpokePool.deposit()` directly, and `deposit()` does not validate quotes — it accepts whatever parameters it receives. Without a signature check, anyone could call `executeDeposit` with an inflated `outputAmount` (causing the deposit to never fill) or a manipulated `fillDeadline`. The implementation's EIP-712 signature over `(inputAmount, outputAmount, fillDeadline)` ensures only signer-approved values are used. The domain separator includes the clone address to prevent cross-clone replay.

### 7. cctpMaxFeeBps / maxOftFeeBps / maxRelayerFee

**Users set fee limits as route params committed at address-generation time.**

- CCTP: `cctpMaxFeeBps` (basis points) — implementation computes `maxFee = depositAmount * cctpMaxFeeBps / 10000` at execution time
- OFT: `maxOftFeeBps` (basis points) — passed through to SponsoredOFTSrcPeriphery
- SpokePool: `maxFeeBps` (basis points) + `price` — implementation checks `(relayerFee + executionFee) * 10000 / inputAmount <= maxFeeBps`

### 8. Execution Fee for Relayer Incentivization

**Each clone has a fixed `executionFee` (in token units) paid to the relayer who calls `executeDeposit`.**

Why: Relayers incur gas costs to call `executeDeposit` (and potentially `deploy`). The fee is fixed rather than percentage-based because gas costs are independent of the deposit amount. The `executionFeeRecipient` is specified at execution time so any relayer can earn the fee.

### 9. Address Reusability

**The same clone proxy can receive and execute multiple deposits over time.**

Why: Enables persistent "deposit addresses" that users can save, share, and reuse — like a traditional address.

The factory's `deployAndExecute()` uses try/catch to handle already-deployed clones gracefully.

## Security Model

- **SponsoredCCTP/OFT Signer**: Trusted address that signs bridge quotes. Compromise allows bad quotes but fees are bounded by user-set `cctpMaxFeeBps`/`maxOftFeeBps`.
- **SpokePool Signer**: Signs `(inputAmount, outputAmount, fillDeadline)` for SpokePool executions. Compromise allows bad `outputAmount` values but bounded by `maxFeeBps`.
- **Admin**: Per-clone admin (set in route params). Can withdraw any tokens from its clone via `adminWithdraw` (for recovery of wrongly sent tokens). Can be a multisig or TimelockController.
- **userWithdrawAddress**: Can withdraw tokens from the clone via `userWithdraw` (escape hatch before execution).
- **Execution Fee**: Fixed `executionFee` (route param, in token units) paid to relayer. User commits to this fee at address-generation time.
- **Nonce/Deadline**: Protocol-specific deadlines (`cctpDeadline`, `oftDeadline`) and nonces are validated by SrcPeriphery. For SpokePool, token balance consumption provides natural replay protection.
- **Cross-clone replay (SpokePool)**: Prevented by including the clone address in the EIP-712 domain separator.

### Trust-Minimized Admin via TimelockController

The `adminWithdrawAddress` field can be set to an OpenZeppelin `TimelockController`. This adds a time delay to all `adminWithdraw` calls, giving users a window to call `userWithdraw` first. No contract changes needed — the TimelockController address is simply set as `adminWithdrawAddress` in the route params at address-generation time.
