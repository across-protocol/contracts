# Counterfactual Deposit Addresses

Gas-optimized system for creating persistent, reusable deposit addresses via deterministic CREATE2 deployment. Supports multiple bridge types: **CCTP**, **OFT** (LayerZero), and **SpokePool** (Across).

## Architecture

**Generic factory + merkle-dispatched proxy + bridge-specific implementations:**

- `CounterfactualDepositFactory` — Bridge-agnostic factory. Deploys clones of `CounterfactualDeposit` deterministically via `Clones.cloneDeterministicWithImmutableArgs`, predicts addresses, and forwards raw calldata to clones.
- `CounterfactualDeposit` — Merkle-dispatched proxy. All clones are instances of this contract. The clone's sole immutable arg is a merkle root. Each leaf is `keccak256(abi.encode(implementation, keccak256(params)))`. Callers prove leaf inclusion, then the proxy delegatecalls the implementation via `ICounterfactualImplementation.execute(params, submitterData)`.
- `CounterfactualDepositSpokePool` — Deposit implementation for Across SpokePool. Verifies EIP-712 signatures itself (since it calls `SpokePool.deposit()` directly) and enforces relayer fee bounds.
- `CounterfactualDepositCCTP` — Deposit implementation for SponsoredCCTP. Builds a `SponsoredCCTPQuote` and calls `SponsoredCCTPSrcPeriphery.depositForBurn()`.
- `CounterfactualDepositOFT` — Deposit implementation for SponsoredOFT (LayerZero). Builds a `Quote` and calls `SponsoredOFTSrcPeriphery.deposit()`. Supports `msg.value` forwarding for LZ native messaging fees.
- `WithdrawImplementation` — Withdraw implementation. Included as a separate merkle leaf in each clone's tree. Authorizes both an `admin` and a `user` address, either of which can withdraw tokens/ETH to any recipient.
- `AdminWithdrawManager` — Contract set as `admin` in withdraw merkle leaves. Enables two withdrawal paths: (1) direct withdraw by a trusted `directWithdrawer` to any recipient, and (2) signed withdraw by anyone with a valid EIP-712 signature from `signer`, always paying out to the `user` committed in the merkle leaf.
- `CounterfactualConstants` — Shared file-level constants (`NATIVE_ASSET`, `BPS_SCALAR`) imported by name.

```
                    CounterfactualDepositFactory (generic)
                    - deploy(implementation, merkleRoot, salt)
                    - execute(depositAddress, executeCalldata)
                    - deployAndExecute(...)
                    - deployIfNeededAndExecute(...)
                    - predictDepositAddress(...)
                              |
                              v
                    CounterfactualDeposit (merkle-dispatched proxy)
                    - execute(implementation, params, submitterData, proof)
                              |
             +----------------+----------------+----------------+
             |                |                |                |
             v                v                v                v
     CCTP Deposit       OFT Deposit      SpokePool       Withdraw
     -> SponsoredCCTP   -> SponsoredOFT  Deposit          Implementation
       SrcPeriphery       SrcPeriphery   -> SpokePool     -> ERC20/ETH
                                           .deposit()       transfer
```

### Call Chain

```
Caller → CALL → Clone (EIP-1167 proxy)
              → DELEGATECALL → CounterfactualDeposit (dispatcher)
                             → verifies merkle proof
                             → DELEGATECALL → Implementation.execute(params, submitterData)
```

- `address(this)` = clone address throughout (correct for EIP-712, token balances)
- `msg.sender` = original caller throughout
- `msg.value` = original value throughout

### Merkle Tree Structure

Each clone's merkle tree typically contains:

- **1+ deposit leaves** — `(depositImplementation, keccak256(depositParams))` for each bridge type. A single clone can support multiple bridge types (e.g. both SpokePool and CCTP), each as a separate leaf with its own implementation and params.
- **1 withdraw leaf** — `(withdrawImplementation, keccak256(withdrawParams))` with `{admin, user}` addresses
- **Padding leaves** as needed (merkle trees require power-of-2 leaf counts)

Deposit params and withdraw params are committed independently, so the same withdraw configuration (admin + user addresses) can be paired with any combination of deposit types.

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
| `executionFee`          | Deposit param         | Fixed fee (in burnToken units) paid to relayer                          |
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
| `executionFee`          | Deposit param         | Fixed fee paid to relayer                                               |
| `amount`                | Argument              | Gross amount of token (includes executionFee)                           |
| `executionFeeRecipient` | Argument              | Address that receives the execution fee                                 |
| `nonce`                 | Argument              | Unique nonce for SponsoredOFT replay protection                         |
| `oftDeadline`           | Argument              | Deadline for the SponsoredOFT quote (validated by SrcPeriphery)         |
| `signature`             | Argument              | Signature from SponsoredOFT quote signer                                |
| `msg.value`             | Argument              | Native ETH for LayerZero messaging fees                                 |

`execute` is `payable` — `msg.value` covers LayerZero native messaging fees, forwarded to `SponsoredOFTSrcPeriphery.deposit{value: msg.value}()`. The relayer pays this and recoups via `executionFee`.

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
| `stableExchangeRate`    | Deposit param         | inputToken per outputToken exchange rate (1e18 scaled), used for fee calculation |
| `maxFeeFixed`           | Deposit param         | Max fixed fee component (in inputToken units), covers gas-like fixed costs       |
| `maxFeeBps`             | Deposit param         | Max variable fee component in basis points, scales with deposit size             |
| `executionFee`          | Deposit param         | Fixed fee paid to relayer calling execute                                        |
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

**Assumption:** The `stableExchangeRate` route param is fixed at address-generation time, so this fee check assumes `inputToken` and `outputToken` are not volatile relative to each other (e.g. stablecoin pairs, or the same token on different chains). If the real market rate drifts significantly from the committed `stableExchangeRate`, the fee check may be too lenient or too strict.

### Depositor Field

The `depositor` parameter passed to `SpokePool.deposit()` is `address(this)` (the clone address). SpokePool refunds for expired deposits go back to the clone, where they can be re-executed or withdrawn.

### Native ETH Deposits

When `inputToken` is set to `NATIVE_ASSET` (`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`) in the route params, users send native ETH to the predicted CREATE2 address instead of ERC20 tokens. At execution time, the clone detects native ETH by checking:

```
isNative = inputToken == NATIVE_ASSET
```

- **Native flow**: `wrappedNativeToken` is substituted as `inputToken` in the `spokePool.deposit{value: depositAmount}()` call so SpokePool recognizes and wraps the ETH. Execution fee paid in ETH via `.call{value}`.
- **ERC20 flow**: existing `forceApprove` + `deposit` path (for any non-`NATIVE_ASSET` inputToken). Execution fee paid in ERC20 via `safeTransfer`.

The clone has a `receive()` function (in `CounterfactualDeposit`) to accept ETH before deployment (sent to the predicted address) and after deployment.

## Withdraw Implementation (`WithdrawImplementation`)

Withdrawals are a separate merkle leaf, not built into the deposit implementations. This decouples withdraw authorization from deposit logic.

| Variable | Source         | Description                                                        |
| -------- | -------------- | ------------------------------------------------------------------ |
| `admin`  | Withdraw param | Admin address authorized to withdraw (e.g. `AdminWithdrawManager`) |
| `user`   | Withdraw param | User address authorized to withdraw (escape hatch)                 |
| `token`  | Argument       | Token to withdraw, or `NATIVE_ASSET` for ETH                       |
| `to`     | Argument       | Recipient address                                                  |
| `amount` | Argument       | Amount to withdraw                                                 |

Both `admin` and `user` can withdraw to any recipient. The `admin` address is typically the `AdminWithdrawManager` contract; the `user` address is the depositor's EOA or multisig.

Native ETH withdrawals are supported via `token = NATIVE_ASSET` (`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`).

## Key Design Decisions

### 1. Generic Factory

**The factory is bridge-agnostic — it takes `bytes32 paramsHash` and `bytes calldata executeCalldata`.**

Why: The factory stores only a 32-byte immutable arg (interpreted as a merkle root by the dispatcher). It forwards raw calldata to clones. Adding a new bridge type requires only a new implementation contract — no factory or dispatcher changes.

`deployAndExecute` and `execute` are `payable` to support bridges that need `msg.value` (e.g. OFT for LayerZero fees). The factory forwards `msg.value` to the clone via low-level `call`.

### 2. Merkle-Dispatched Proxy

**Each clone is an EIP-1167 proxy of `CounterfactualDeposit` — a generic dispatcher that verifies merkle proofs before delegatecalling implementations.**

Why: A single clone can support multiple actions (deposit + withdraw) without the implementation needing to know about other implementations. The merkle root committed at deployment time defines the full set of authorized `(implementation, params)` pairs. New implementation types can be added to a clone's merkle tree without changing any contracts.

The leaf format `keccak256(abi.encode(implementation, keccak256(params)))` commits to both the code and the configuration, preventing implementation substitution attacks.

### 3. Separate Withdraw Leaf

**Withdrawals are a separate `WithdrawImplementation` merkle leaf, not built into deposit implementations.**

Why: This cleanly separates concerns — deposit implementations only handle bridging logic, and withdraw authorization is configured independently. The same `WithdrawParams{admin, user}` leaf works with any deposit type. A single withdraw leaf per clone authorizes both the admin and user, minimizing merkle tree size.

### 4. Separate `execute()` Entrypoint

**The factory provides `execute()` for forwarding calldata to already-deployed clones.**

Why: `deployAndExecute` reverts if the clone already exists. For subsequent deposits to an existing clone, callers can either call the clone directly or use `factory.execute()`. The factory entrypoint is a convenience wrapper that forwards `msg.value` and bubbles up reverts.

### 5. Immutable Distribution (Gas Optimization)

**Chain-wide constants (srcPeriphery, sourceDomain, spokePool, signer) are immutable in the implementation, not the clone.**

Why: These values are identical across all deposit addresses on a chain. Storing them in each clone wastes gas. The clone only stores a 32-byte merkle root via immutable args. Chain-wide constants live in the implementation's bytecode and are accessible directly since EIP-1167 proxies use delegatecall.

### 6. OZ Clones with Hash-Only Immutable Args

**Each clone stores only a merkle root (32 bytes), not the full params.**

[EIP-1167](https://eips.ethereum.org/EIPS/eip-1167) defines a minimal proxy contract — 45 bytes of bytecode that forwards every call to a fixed implementation via `delegatecall`. OpenZeppelin's `Clones.cloneDeterministicWithImmutableArgs` extends this by appending arbitrary bytes after the proxy bytecode.

The factory stores a 32-byte merkle root as the clone's sole immutable arg — 77 bytes total (45-byte EIP-1167 proxy + 32-byte root). Storing full params as immutable args would cost ~595+ bytes of deployed code, saving ~103k gas on deployment. The tradeoff is ~6k gas more per execution (calldata for full params + one keccak256 hash per proof verification), but since each deposit address is deployed once and potentially reused many times, the net savings are significant.

### 7. Signature Verification: SpokePool vs CCTP/OFT

**CCTP and OFT implementations do NOT verify signatures — the SpokePool implementation does.**

Why: CCTP and OFT implementations forward deposits to a `SrcPeriphery` contract, which already validates the quote signature, nonce, and deadline before bridging. The implementation is just a pass-through, so adding its own signature check would be redundant.

The SpokePool implementation calls `SpokePool.deposit()` directly, and `deposit()` does not validate quotes — it accepts whatever parameters it receives. Without a signature check, anyone could call `execute` with an inflated `outputAmount` (causing the deposit to never fill) or a manipulated `fillDeadline`. The implementation's EIP-712 signature over `(inputAmount, outputAmount, exclusiveRelayer, exclusivityDeadline, quoteTimestamp, fillDeadline, signatureDeadline)` ensures only signer-approved values are used. The `signatureDeadline` bounds the window during which a signature can be replayed against a re-funded clone. The domain separator includes the clone address to prevent cross-clone replay.

### 8. Fee Limits

**Users set fee limits as deposit params committed at address-generation time.**

- CCTP: `cctpMaxFeeBps` (basis points) — implementation computes `maxFee = depositAmount * cctpMaxFeeBps / 10000` at execution time
- OFT: `maxOftFeeBps` (basis points) — passed through to SponsoredOFTSrcPeriphery
- SpokePool: `maxFeeFixed` (token units) + `maxFeeBps` (basis points) — implementation checks `relayerFee + executionFee <= maxFeeFixed + maxFeeBps * inputAmount / 10000`

### 9. Execution Fee for Relayer Incentivization

**Each deposit leaf has a fixed `executionFee` (in token units) paid to the relayer who calls `execute`.**

Why: Relayers incur gas costs to call `execute` (and potentially `deploy`). The fee is fixed rather than percentage-based because gas costs are independent of the deposit amount. The `executionFeeRecipient` is specified at execution time so any relayer can earn the fee.

### 10. Address Reusability

**The same clone proxy can receive and execute multiple deposits over time.**

Why: Enables persistent "deposit addresses" that users can save, share, and reuse — like a traditional address.

For subsequent deposits, callers can call the clone directly or use `factory.execute()`. `deployAndExecute()` reverts if the clone already exists; `deployIfNeededAndExecute()` skips deployment if the clone is already deployed (checked via `code.length`), making it safe to call regardless of deployment state.

## Deployment

All 7 counterfactual contracts are deployed from a single EOA in a fixed order to achieve **the same contract addresses on every chain**. Since `CREATE` addresses depend only on `(sender, nonce)`, deploying the same contracts in the same order from the same address (starting at nonce 0) produces identical addresses everywhere.

### Deployment Order

| Nonce | Contract                         |
| ----- | -------------------------------- |
| 0     | `CounterfactualDeposit`          |
| 1     | `CounterfactualDepositFactory`   |
| 2     | `WithdrawImplementation`         |
| 3     | `CounterfactualDepositSpokePool` |
| 4     | `CounterfactualDepositCCTP`      |
| 5     | `CounterfactualDepositOFT`       |
| 6     | `AdminWithdrawManager`           |

### How to Deploy

1. **Choose a fresh derivation index** — pick an index from your mnemonic that has never sent a transaction on the target chain (nonce must be 0).

2. **Get the deployer address** to know which address to fund (omit `--mnemonic-index` to use index 0):

   ```bash
   source .env
   cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index <DERIVATION_INDEX>
   ```

3. **Fund the deployer** on the target chain with enough ETH for gas.

4. **Simulate** (omit `--ffi` to dry-run without broadcasting):

   ```bash
   source .env
   DEPLOYER_INDEX=<DERIVATION_INDEX> forge script \
     script/counterfactual/DeployAllCounterfactual.s.sol:DeployAllCounterfactual \
     --sig "run(string,address,address,address,address,uint32,address,uint32,address,address,bool)" \
     $NODE_URL \
     <spokePool> <signer> <wrappedNativeToken> \
     <cctpPeriphery> <cctpDomain> <oftPeriphery> <oftEid> \
     <owner> <directWithdrawer> \
     false \
     --rpc-url $NODE_URL -vvvv
   ```

5. **Deploy** (set `broadcast` to `true` and add `--ffi`):

   ```bash
   DEPLOYER_INDEX=<DERIVATION_INDEX> forge script \
     script/counterfactual/DeployAllCounterfactual.s.sol:DeployAllCounterfactual \
     --sig "run(string,address,address,address,address,uint32,address,uint32,address,address,bool)" \
     $NODE_URL \
     <spokePool> <signer> <wrappedNativeToken> \
     <cctpPeriphery> <cctpDomain> <oftPeriphery> <oftEid> \
     <owner> <directWithdrawer> \
     true \
     --rpc-url $NODE_URL --ffi -vvvv
   ```

### Skipping Contracts

If a chain doesn't need certain implementations (e.g., no CCTP or OFT support), set the `SKIP` env var with a comma-separated list of deployment indices from the table above:

```bash
DEPLOYER_INDEX=<DERIVATION_INDEX> SKIP=4,5 forge script \
  script/counterfactual/DeployAllCounterfactual.s.sol:DeployAllCounterfactual \
  --sig "run(...)" \
  ... \
  true \
  --rpc-url $NODE_URL --ffi -vvvv
```

Skipped deployments burn the nonce with a 0-value self-transfer so that subsequent contracts still land at the correct addresses.

### Important

- **Never send any other transactions** from the deployer address before all 7 deploys complete — this would consume a nonce and break the address mapping.
- **Use the same derivation index** across all chains to get the same deployer address and thus the same contract addresses.
- Individual deploy scripts can still be run standalone. `DEPLOYER_INDEX` defaults to 0 if not set.

## Security Model

- **SponsoredCCTP/OFT Signer**: Trusted address that signs bridge quotes. Compromise allows bad quotes but fees are bounded by user-set `cctpMaxFeeBps`/`maxOftFeeBps`.
- **SpokePool Signer**: Signs `(inputAmount, outputAmount, exclusiveRelayer, exclusivityDeadline, quoteTimestamp, fillDeadline, signatureDeadline)` for SpokePool executions. Compromise allows bad `outputAmount` values but bounded by `maxFeeFixed + maxFeeBps`.
- **Admin** (withdraw leaf): Address authorized to withdraw from the clone. Typically `AdminWithdrawManager`, which restricts access via `directWithdrawer` and `signer`. Can be a multisig or TimelockController for trust-minimized setups.
- **User** (withdraw leaf): Address authorized to withdraw from the clone (escape hatch before execution). Can be the depositor's EOA or multisig.
- **Execution Fee**: Fixed `executionFee` (deposit param, in token units) paid to relayer. User commits to this fee at address-generation time.
- **Nonce/Deadline**: Protocol-specific deadlines (`cctpDeadline`, `oftDeadline`) and nonces are validated by SrcPeriphery. For SpokePool, token balance consumption provides natural replay protection.
- **Cross-clone replay (SpokePool)**: Prevented by including the clone address in the EIP-712 domain separator.
- **Merkle proof**: Each `execute` call verifies inclusion against the clone's committed merkle root. Callers cannot invoke arbitrary implementations or use params not committed at deployment time.

### AdminWithdrawManager

The `AdminWithdrawManager` is designed to be set as `admin` in withdraw merkle leaves, providing two withdrawal paths:

1. **Direct withdraw** (`directWithdraw`) — A trusted `directWithdrawer` address (e.g. a bot or multisig) calls `clone.execute()` with the withdraw implementation, params, submitter data, and merkle proof. The caller encodes the `(token, to, amount)` submitter data, enabling withdrawals to any recipient.

2. **Signed withdraw to user** (`signedWithdrawToUser`) — Anyone can trigger a withdrawal by providing a valid EIP-712 signature from `signer`. The recipient is always the `user` address committed in the withdraw leaf's `WithdrawParams`, enforced on-chain by reading `abi.decode(params, (WithdrawParams)).user`. This allows permissionless fund recovery to the user without trusting the caller.

The manager uses EIP-712 signatures with typehash `SignedWithdraw(address depositAddress,address token,uint256 amount,uint256 deadline)`. The `owner` can update `directWithdrawer` and `signer` addresses.

### Trust-Minimized Admin via TimelockController

The `admin` field in a withdraw leaf can be set to an OpenZeppelin `TimelockController`. This adds a time delay to all admin withdrawals, giving users a window to call `userWithdraw` (via the same withdraw leaf as `user`) first. No contract changes needed — the TimelockController address is simply set as `admin` in `WithdrawParams` at address-generation time.
