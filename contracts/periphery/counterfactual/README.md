# Counterfactual Deposit Addresses

Gas-optimized system for creating persistent, reusable deposit addresses via deterministic CREATE2 deployment. Supports multiple bridge types: **CCTP**, **OFT** (LayerZero), and **SpokePool** (Across).

## Architecture

**Generic factory + bridge-specific implementations using OpenZeppelin EIP-1167 Clones with Immutable Args:**

- `CounterfactualDepositFactory` — Bridge-agnostic factory. Deploys clones deterministically via `Clones.cloneDeterministicWithImmutableArgs`, predicts addresses, and forwards raw calldata to clones. Takes `bytes32 paramsHash` — the caller hashes the params off-chain, and the factory never reads struct fields.
- `CounterfactualDepositBase` — Abstract base contract inherited by all implementations. Provides shared logic: params hash verification (`_verifyParamsHash`), generic bytes-based `adminWithdraw(bytes,...)`, `userWithdraw(bytes,...)`, and `verifyUserWithdrawer(bytes)`, and constants (`BPS_SCALAR`, `EXCHANGE_RATE_SCALAR`). Withdraw functions take raw `bytes calldata params` so the `AdminWithdrawManager` can interact with any implementation without knowing the specific struct type. Each implementation overrides `_getUserWithdrawAddress` and `_getAdminWithdrawAddress` to decode its own immutables struct.
- `CounterfactualDepositCCTP` — Implementation for deposits via SponsoredCCTP. Builds a `SponsoredCCTPQuote` and calls `SponsoredCCTPSrcPeriphery.depositForBurn()`.
- `CounterfactualDepositOFT` — Implementation for deposits via SponsoredOFT (LayerZero). Builds a `Quote` and calls `SponsoredOFTSrcPeriphery.deposit()`. Supports `msg.value` forwarding for LZ native messaging fees.
- `CounterfactualDepositSpokePool` — Implementation for deposits via Across SpokePool. Verifies EIP-712 signatures itself (since it calls `SpokePool.deposit()` directly) and enforces relayer fee bounds.
- `AdminWithdrawManager` — Contract set as `adminWithdrawAddress` on clones. Enables two withdrawal paths: (1) direct withdraw by a trusted `directWithdrawer` to any recipient, and (2) signed withdraw by anyone with a valid EIP-712 signature from `signer`, always paying out to the clone's `userWithdrawAddress`.

```
                    CounterfactualDepositFactory (generic)
                    - deploy(implementation, paramsHash, salt)
                    - execute(depositAddress, executeCalldata)
                    - deployAndExecute(implementation, paramsHash, salt, executeCalldata)
                    - deployIfNeededAndExecute(implementation, paramsHash, salt, executeCalldata)
                    - predictDepositAddress(implementation, paramsHash, salt)
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
| `destinationDomain`     | Deposit param         | CCTP destination domain (e.g. 3 for Hyperliquid)                        |
| `mintRecipient`         | Deposit param         | DstPeriphery handler contract on destination                            |
| `burnToken`             | Deposit param         | Token to burn (e.g. USDC address as bytes32)                            |
| `destinationCaller`     | Deposit param         | Permissioned bot that calls `receiveMessage` on destination             |
| `cctpMaxFeeBps`         | Deposit param         | Max CCTP fee in bps (computed to `maxFee` at execution time)            |
| `minFinalityThreshold`  | Deposit param         | Minimum finality before CCTP attestation                                |
| `maxBpsToSponsor`       | Deposit param         | Max bps of amount the relayer can sponsor                               |
| `maxUserSlippageBps`    | Deposit param         | Slippage tolerance for fees on destination                              |
| `finalRecipient`        | Deposit param         | Ultimate receiver on destination chain                                  |
| `finalToken`            | Deposit param         | Token recipient receives on destination                                 |
| `destinationDex`        | Deposit param         | DEX on HyperCore for swaps                                              |
| `accountCreationMode`   | Deposit param         | Standard (0) or FromUserFunds (1)                                       |
| `executionMode`         | Deposit param         | DirectToCore (0), ArbitraryActionsToCore (1), ArbitraryActionsToEVM (2) |
| `actionData`            | Deposit param         | Encoded action data for arbitrary execution modes                       |
| `executionFee`          | Execution param       | Fixed fee (in burnToken units) paid to relayer                          |
| `userWithdrawAddress`   | Execution param       | Address authorized to call `userWithdraw()`                             |
| `adminWithdrawAddress`  | Execution param       | Address authorized to call `adminWithdraw()`                            |
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
| `dstEid`                | Deposit param         | OFT destination endpoint ID                                             |
| `destinationHandler`    | Deposit param         | Composer contract on destination (OFT `to` param)                       |
| `token`                 | Deposit param         | Local token address (the OFT token on source chain)                     |
| `maxOftFeeBps`          | Deposit param         | Max OFT bridge fee in bps                                               |
| `lzReceiveGasLimit`     | Deposit param         | Gas limit for `lzReceive` on destination                                |
| `lzComposeGasLimit`     | Deposit param         | Gas limit for `lzCompose` on destination                                |
| `maxBpsToSponsor`       | Deposit param         | Max bps of amount the relayer can sponsor                               |
| `maxUserSlippageBps`    | Deposit param         | Slippage tolerance for swap on destination                              |
| `finalRecipient`        | Deposit param         | User address on destination                                             |
| `finalToken`            | Deposit param         | Final token user receives                                               |
| `destinationDex`        | Deposit param         | Destination DEX on HyperCore                                            |
| `accountCreationMode`   | Deposit param         | Standard (0) or FromUserFunds (1)                                       |
| `executionMode`         | Deposit param         | DirectToCore (0), ArbitraryActionsToCore (1), ArbitraryActionsToEVM (2) |
| `refundRecipient`       | Deposit param         | LZ refund recipient for excess native messaging fees                    |
| `actionData`            | Deposit param         | Encoded action data for arbitrary execution modes                       |
| `executionFee`          | Execution param       | Fixed fee paid to relayer                                               |
| `userWithdrawAddress`   | Execution param       | Address authorized to call `userWithdraw()`                             |
| `adminWithdrawAddress`  | Execution param       | Address authorized to call `adminWithdraw()`                            |
| `amount`                | Argument              | Gross amount of token (includes executionFee)                           |
| `executionFeeRecipient` | Argument              | Address that receives the execution fee                                 |
| `nonce`                 | Argument              | Unique nonce for SponsoredOFT replay protection                         |
| `oftDeadline`           | Argument              | Deadline for the SponsoredOFT quote (validated by SrcPeriphery)         |
| `signature`             | Argument              | Signature from SponsoredOFT quote signer                                |
| `msg.value`             | Argument              | Native ETH for LayerZero messaging fees                                 |

`executeDeposit` is `payable` — `msg.value` covers LayerZero native messaging fees, forwarded to `SponsoredOFTSrcPeriphery.deposit{value: msg.value}()`. The relayer pays this and recoups via `executionFee`.

Signature verification, nonce tracking, and `oftDeadline` enforcement are handled by `SponsoredOFTSrcPeriphery`.

## SpokePool Implementation (`CounterfactualDepositSpokePool`)

| Variable                | Source                | Description                                                                      |
| ----------------------- | --------------------- | -------------------------------------------------------------------------------- |
| `spokePool`             | Constructor immutable | Across SpokePool contract address                                                |
| `signer`                | Constructor immutable | Address that authorizes execution parameters via EIP-712                         |
| `wrappedNativeToken`    | Constructor immutable | WETH address, substituted as inputToken for native deposits to SpokePool         |
| `destinationChainId`    | Deposit param         | Across destination chain ID                                                      |
| `inputToken`            | Deposit param         | Token deposited on source (as bytes32), or `NATIVE_ASSET` for native ETH         |
| `outputToken`           | Deposit param         | Token received on destination (as bytes32)                                       |
| `recipient`             | Deposit param         | Recipient on destination                                                         |
| `message`               | Deposit param         | Arbitrary message forwarded to recipient                                         |
| `stableExchangeRate`    | Execution param       | inputToken per outputToken exchange rate (1e18 scaled), used for fee calculation |
| `maxFeeFixed`           | Execution param       | Max fixed fee component (in inputToken units), covers gas-like fixed costs       |
| `maxFeeBps`             | Execution param       | Max variable fee component in basis points, scales with deposit size             |
| `executionFee`          | Execution param       | Fixed fee paid to relayer calling execute                                        |
| `userWithdrawAddress`   | Execution param       | Address authorized to call `userWithdraw()`                                      |
| `adminWithdrawAddress`  | Execution param       | Address authorized to call `adminWithdraw()`                                     |
| `inputAmount`           | Argument (signed)     | Gross amount of inputToken (includes executionFee)                               |
| `outputAmount`          | Argument (signed)     | Output amount passed to SpokePool                                                |
| `exclusiveRelayer`      | Argument (signed)     | Optional exclusive relayer (bytes32(0) for none)                                 |
| `exclusivityDeadline`   | Argument (signed)     | Seconds of relayer exclusivity (0 for none)                                      |
| `executionFeeRecipient` | Argument              | Address that receives the execution fee                                          |
| `quoteTimestamp`        | Argument (signed)     | Quote timestamp from Across API (SpokePool validates recency)                    |
| `fillDeadline`          | Argument (signed)     | Timestamp by which the deposit must be filled                                    |
| `signatureDeadline`     | Argument (signed)     | Timestamp after which the signature is no longer valid                           |
| `signature`             | Argument              | EIP-712 signature from signer over signed arguments                              |

### EIP-712 Signature Verification

Unlike CCTP/OFT (where `SrcPeriphery` verifies signatures), the SpokePool implementation verifies signatures itself since it calls `SpokePool.deposit()` directly.

- **Domain separator** uses OpenZeppelin's `EIP712` base contract with `address(this)` (the clone address) — prevents cross-clone replay
- **No nonce needed**: token balance is consumed on execution (natural replay protection), and short deadlines bound the replay window for re-funded clones
- **Typehash**: `ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)`
- **Signer** is an immutable set in the implementation constructor, shared across all clones

### Fee Check

The implementation enforces that the total fee (relayer + execution) doesn't exceed a combined fixed + variable cap:

```
outputInInputToken = outputAmount * stableExchangeRate / 1e18
relayerFee = depositAmount - outputInInputToken  (0 if negative)
totalFee = relayerFee + executionFee
maxFee = maxFeeFixed + (maxFeeBps * inputAmount) / 10000
if totalFee > maxFee:
    revert MaxFee
```

The two-component cap (`maxFeeFixed + maxFeeBps`) handles deposits of varying sizes. Fixed costs (origin/destination gas, execution fee) don't scale with amount, so a pure bps cap would be too restrictive for small deposits and too permissive for large ones. `maxFeeFixed` covers the fixed costs, `maxFeeBps` covers the relayer fee that scales with size.

**Assumption:** The `stableExchangeRate` route immutable is fixed at address-generation time, so this fee check assumes `inputToken` and `outputToken` are not volatile relative to each other (e.g. stablecoin pairs, or the same token on different chains). If the real market rate drifts significantly from the committed `stableExchangeRate`, the fee check may be too lenient or too strict.

### Depositor Field

The `depositor` parameter passed to `SpokePool.deposit()` is `address(this)` (the clone address). SpokePool refunds for expired deposits go back to the clone, where they can be re-executed or withdrawn via `userWithdraw`.

### Native ETH Deposits

When `inputToken` is set to `NATIVE_ASSET` (`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`) in the route params, users send native ETH to the predicted CREATE2 address instead of ERC20 tokens. At execution time, the clone detects native ETH by checking:

```
isNative = inputToken == NATIVE_ASSET
```

- **Native flow**: `wrappedNativeToken` is substituted as `inputToken` in the `spokePool.deposit{value: depositAmount}()` call so SpokePool recognizes and wraps the ETH. Execution fee paid in ETH via `_transferOut`.
- **ERC20 flow**: existing `forceApprove` + `deposit` path (for any non-`NATIVE_ASSET` inputToken). Execution fee paid in ERC20 via `_transferOut`.

The clone has a `receive()` function to accept ETH before deployment (sent to the predicted address) and after deployment.

**Withdraw**: `userWithdraw` and `adminWithdraw` accept `token = NATIVE_ASSET` (`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`) to withdraw native ETH from the clone.

## Key Design Decisions

### 1. Generic Factory

**The factory is bridge-agnostic — it takes `bytes32 paramsHash` and `bytes calldata executeCalldata`.**

Why: Each bridge type defines its own immutables struct. The caller hashes the params off-chain, and the factory stores the hash as the clone's immutable arg. It forwards raw calldata to clones. This means adding a new bridge type requires only a new implementation contract — no factory changes.

`deployAndExecute` and `execute` are `payable` to support bridges that need `msg.value` (e.g. OFT for LayerZero fees). The factory forwards `msg.value` to the clone via low-level `call`.

### 2. Separate `execute()` Entrypoint

**The factory provides `execute()` for forwarding calldata to already-deployed clones.**

Why: `deployAndExecute` reverts if the clone already exists. For subsequent deposits to an existing clone, callers can either call the clone directly or use `factory.execute()`. The factory entrypoint is a convenience wrapper that forwards `msg.value` and bubbles up reverts.

### 3. Immutable Distribution (Gas Optimization)

**Chain-wide constants (srcPeriphery, sourceDomain, spokePool, signer) are immutable in the Executor, not the clone.**

Why: These values are identical across all deposit addresses on a chain. Storing them in each clone wastes gas. The clone only stores route-specific parameters via a hash of the immutable args. Chain-wide constants live in the implementation's bytecode and are accessible directly since EIP-1167 proxies use delegatecall.

### 4. OZ Clones with Hash-Only Immutable Args

**Each clone stores only a keccak256 hash (32 bytes) of the route parameters, not the full params.**

[EIP-1167](https://eips.ethereum.org/EIPS/eip-1167) defines a minimal proxy contract — 45 bytes of bytecode that forwards every call to a fixed implementation via `delegatecall`. OpenZeppelin's `Clones.cloneDeterministicWithImmutableArgs` extends this by appending arbitrary bytes after the proxy bytecode.

The caller computes `keccak256(abi.encode(params))` off-chain and passes the 32-byte hash to the factory, which stores it as the clone's sole immutable arg. At execution time, the caller passes the full params struct; the implementation hashes it and verifies against the stored hash before proceeding.

Storing full params as immutable args would cost ~595+ bytes of deployed code. With a hash, the clone stores only 77 bytes total (45-byte EIP-1167 proxy + 32-byte hash). This saves ~103k gas on deployment. The tradeoff is ~6k gas more per execution (calldata for full params + one keccak256 hash), but since each deposit address is deployed once and potentially reused many times, the net savings are significant.

### 5. Signature Verification: SpokePool vs CCTP/OFT

**CCTP and OFT implementations do NOT verify signatures — the SpokePool implementation does.**

Why: CCTP and OFT implementations forward deposits to a `SrcPeriphery` contract, which already validates the quote signature, nonce, and deadline before bridging. The implementation is just a pass-through, so adding its own signature check would be redundant.

The SpokePool implementation calls `SpokePool.deposit()` directly, and `deposit()` does not validate quotes — it accepts whatever parameters it receives. Without a signature check, anyone could call `executeDeposit` with an inflated `outputAmount` (causing the deposit to never fill) or a manipulated `fillDeadline`. The implementation's EIP-712 signature over `(inputAmount, outputAmount, exclusiveRelayer, exclusivityDeadline, quoteTimestamp, fillDeadline, signatureDeadline)` ensures only signer-approved values are used. The `signatureDeadline` bounds the window during which a signature can be replayed against a re-funded clone. The domain separator includes the clone address to prevent cross-clone replay.

### 7. cctpMaxFeeBps / maxOftFeeBps / maxRelayerFee

**Users set fee limits as route params committed at address-generation time.**

- CCTP: `cctpMaxFeeBps` (basis points) — implementation computes `maxFee = depositAmount * cctpMaxFeeBps / 10000` at execution time
- OFT: `maxOftFeeBps` (basis points) — passed through to SponsoredOFTSrcPeriphery
- SpokePool: `maxFeeFixed` (token units) + `maxFeeBps` (basis points) — implementation checks `relayerFee + executionFee <= maxFeeFixed + maxFeeBps * inputAmount / 10000`

### 8. Execution Fee for Relayer Incentivization

**Each clone has a fixed `executionFee` (in token units) paid to the relayer who calls `executeDeposit`.**

Why: Relayers incur gas costs to call `executeDeposit` (and potentially `deploy`). The fee is fixed rather than percentage-based because gas costs are independent of the deposit amount. The `executionFeeRecipient` is specified at execution time so any relayer can earn the fee.

### 9. Address Reusability

**The same clone proxy can receive and execute multiple deposits over time.**

Why: Enables persistent "deposit addresses" that users can save, share, and reuse — like a traditional address.

For subsequent deposits, callers can call the clone directly or use `factory.execute()`. `deployAndExecute()` reverts if the clone already exists; `deployIfNeededAndExecute()` skips deployment if the clone is already deployed (checked via `code.length`), making it safe to call regardless of deployment state.

## Security Model

- **SponsoredCCTP/OFT Signer**: Trusted address that signs bridge quotes. Compromise allows bad quotes but fees are bounded by user-set `cctpMaxFeeBps`/`maxOftFeeBps`.
- **SpokePool Signer**: Signs `(inputAmount, outputAmount, exclusiveRelayer, exclusivityDeadline, quoteTimestamp, fillDeadline, signatureDeadline)` for SpokePool executions. Compromise allows bad `outputAmount` values but bounded by `maxFeeFixed + maxFeeBps`.
- **Admin**: Per-clone admin (set in route params). Can withdraw any tokens from its clone via `adminWithdraw` (for recovery of wrongly sent tokens). Can be a multisig or TimelockController.
- **userWithdrawAddress**: Can withdraw tokens from the clone via `userWithdraw` (escape hatch before execution).
- **Execution Fee**: Fixed `executionFee` (route param, in token units) paid to relayer. User commits to this fee at address-generation time.
- **Nonce/Deadline**: Protocol-specific deadlines (`cctpDeadline`, `oftDeadline`) and nonces are validated by SrcPeriphery. For SpokePool, token balance consumption provides natural replay protection.
- **Cross-clone replay (SpokePool)**: Prevented by including the clone address in the EIP-712 domain separator.

### AdminWithdrawManager

The `AdminWithdrawManager` is designed to be set as the `adminWithdrawAddress` on all clones, providing two withdrawal paths:

1. **Direct withdraw** (`directWithdraw`) — A trusted `directWithdrawer` address (e.g. a bot or multisig) can call with arbitrary calldata forwarded to the clone. The caller encodes the implementation-specific `adminWithdraw` call, enabling withdrawals to any recipient.

2. **Signed withdraw to user** (`signedWithdrawToUser`) — Anyone can trigger a withdrawal by providing a valid EIP-712 signature from `signer`. The recipient is always the clone's `userWithdrawAddress`, enforced on-chain by `adminWithdrawToUser`. This allows permissionless fund recovery to the user without trusting the caller.

The manager uses EIP-712 signatures with typehash `SignedWithdraw(address depositAddress,address token,uint256 amount,uint256 deadline)`. The `owner` can update `directWithdrawer` and `signer` addresses.

The `adminWithdrawToUser(bytes calldata params, address token, uint256 amount)` function on `CounterfactualDepositBase` enforces the recipient as `userWithdrawAddress` on-chain, so the manager doesn't need to resolve or specify the recipient. The generic `adminWithdraw(bytes calldata params, address token, address to, uint256 amount)` is used by `directWithdraw` where the caller specifies any recipient.

### Trust-Minimized Admin via TimelockController

The `adminWithdrawAddress` field can be set to an OpenZeppelin `TimelockController`. This adds a time delay to all `adminWithdraw` calls, giving users a window to call `userWithdraw` first. No contract changes needed — the TimelockController address is simply set as `adminWithdrawAddress` in the route params at address-generation time.
