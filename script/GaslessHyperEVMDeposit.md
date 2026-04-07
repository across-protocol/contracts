# Gasless HyperEVM Deposit Flows (ACP-69)

Two gasless withdrawal flows from Hyperliquid via Across Protocol. In both cases, the user never needs HYPE for gas — a bot submits all on-chain transactions.

## Prerequisites (Both Flows)

**Step 0: Core → EVM transfer**

The user's tokens start on HyperCore (Hyperliquid L1). They must first be bridged to HyperEVM via a `sendAsset` to the token's system address.

```
User signs HL API request (off-chain, gasless)
    → sendAsset to system address (e.g. 0x2000...0000 for token index 0)
    → Protocol mints ERC20 tokens to user on HyperEVM
```

The system address format is `0x20` + token index in big-endian. The user now holds ERC20 tokens on HyperEVM but has no HYPE for gas.

---

## Flow 1: EIP-3009 (`receiveWithAuthorization`)

**For tokens that support EIP-3009** (e.g., USDC — implements `receiveWithAuthorization`).

This is the simplest flow. The user signs **one message** and the bot submits **one transaction**.

### How it works

```
┌─────────┐                    ┌─────────┐                    ┌────────────────────┐
│  User   │                    │   Bot   │                    │ SpokePoolPeriphery │
└────┬────┘                    └────┬────┘                    └─────────┬──────────┘
     │                              │                                   │
     │  1. Sign receiveWithAuth     │                                   │
     │  ─────────────────────────►  │                                   │
     │  (off-chain EIP-712 sig)     │                                   │
     │                              │                                   │
     │                              │  2. depositWithAuthorization()    │
     │                              │  ───────────────────────────────► │
     │                              │  (bot pays gas)                   │
     │                              │                                   │
     │                              │                    3. Token calls │
     │                              │                    receiveWithAuth│
     │                              │                    (pulls from    │
     │                              │                     user → periph)│
     │                              │                                   │
     │                              │                    4. Periphery   │
     │                              │                    deposits into  │
     │                              │                    SpokePool      │
     └──────────────────────────────┴───────────────────────────────────┘
```

### Signature details

The user signs an EIP-712 `ReceiveWithAuthorization` message on the **token's domain**:

```
Domain: Token contract (e.g. USDC FiatTokenV2)

ReceiveWithAuthorization(
    address from,       // user
    address to,         // SpokePoolPeriphery
    uint256 value,      // inputAmount + submissionFee
    uint256 validAfter, // 0 (always valid)
    uint256 validBefore,// type(uint256).max (never expires)
    bytes32 nonce       // witness (see below)
)
```

**The nonce is a witness** — it's `keccak256(BRIDGE_WITNESS_IDENTIFIER, abi.encode(depositData))`. This binds the authorization to the specific deposit parameters (amount, recipient, destination chain, etc.), preventing the bot from using the signature for a different deposit.

### Key properties

- **1 user signature** (receiveWithAuthorization)
- **1 bot transaction** (receiveWithAuthorization)
- **No on-chain approval needed** — EIP-3009 transfers tokens directly via the signature
- **Replay protection** — the witness/nonce is unique per deposit and tracked by the token contract
- The `SpokePoolPeriphery` calls `receiveWithAuthorization` on the token, which verifies the signature, transfers tokens from user → periphery, then deposits into the SpokePool

---

## Flow 2: ERC-2612 Permit

**For tokens that support ERC-2612 but NOT EIP-3009** (e.g., USDH, or any standard ERC20Permit token).

This is a two-step flow. The user signs **two messages** and the bot submits **two transactions**.

### How it works

```
┌─────────┐                    ┌─────────┐                    ┌────────────────────┐
│  User   │                    │   Bot   │                    │ SpokePoolPeriphery │
└────┬────┘                    └────┬────┘                    └─────────┬──────────┘
     │                              │                                   │
     │  1a. Sign permit(infinite)   │                                   │
     │  ─────────────────────────►  │                                   │
     │                              │                                   │
     │                              │  1b. token.permit()               │
     │                              │  ───────────────────►  Token      │
     │                              │  (sets allowance:                 │
     │                              │   user → periphery)               │
     │                              │                                   │
     │  2a. Sign depositData        │                                   │
     │  ─────────────────────────►  │                                   │
     │  (EIP-712 on periphery       │                                   │
     │   domain)                    │                                   │
     │                              │                                   │
     │                              │  2b. depositWithPermit()          │
     │                              │  ───────────────────────────────► │
     │                              │  (empty permit sig + deposit sig) │
     │                              │                                   │
     │                              │                    3. Periphery   │
     │                              │                    transferFrom   │
     │                              │                    (uses existing │
     │                              │                     allowance)    │
     │                              │                                   │
     │                              │                    4. Deposits    │
     │                              │                    into SpokePool │
     └──────────────────────────────┴───────────────────────────────────┘
```

### Step 1: Permit approval (one-time)

The user signs an ERC-2612 `Permit` on the **token's domain**, granting infinite allowance to the periphery:

```
Domain: Token contract (e.g. USDH)

Permit(
    address owner,   // user
    address spender,  // SpokePoolPeriphery
    uint256 value,    // type(uint256).max (infinite)
    uint256 nonce,    // token.nonces(user)
    uint256 deadline  // type(uint256).max (never expires)
)
```

The bot submits `token.permit(user, periphery, max, deadline, v, r, s)` on-chain. After this, the periphery has infinite allowance to pull tokens from the user. **This only needs to be done once per user/token pair.**

### Step 2: Gasless deposit (per transfer)

The user signs an EIP-712 `DepositData` message on the **periphery's domain**:

```
Domain: "ACROSS-PERIPHERY" v1.0.0

DepositData(
    Fees submissionFees,
    BaseDepositData baseDepositData,
    uint256 inputAmount,
    address spokePool,
    uint256 nonce  // periphery.permitNonces(user), sequential
)
```

The bot calls `depositWithPermit(user, depositData, 0, emptyPermitSig, depositDataSignature)`:

- The `permitSignature` is an empty 65-byte array — the `try/catch` in the periphery gracefully handles this since the allowance already exists from Step 1
- The `depositDataSignature` proves the user authorized this specific deposit
- The periphery calls `transferFrom` (using the existing allowance), then deposits into the SpokePool

### Key properties

- **2 user signatures** (permit + depositData), but permit is one-time
- **2 bot transactions** (permit + depositWithPermit), but permit is one-time
- **Sequential nonces** — `depositData.nonce` must equal `periphery.permitNonces(user)`, incrementing by 1 each deposit
- **Replay protection** — the periphery validates and increments the nonce, and verifies the deposit data signature

---

## Comparison

|                        | EIP-3009                                   | ERC-2612 Permit                  |
| ---------------------- | ------------------------------------------ | -------------------------------- |
| **Token requirement**  | Must implement `receiveWithAuthorization`  | Must implement ERC-2612 `permit` |
| **User actions**       | 1 signature                                | 2 signatures (1 one-time)        |
| **Bot transactions**   | 1                                          | 2 (1 one-time)                   |
| **On-chain approval**  | Not needed                                 | One-time permit tx               |
| **Nonce type**         | Witness-based (random, unique per deposit) | Sequential from periphery        |
| **Example tokens**     | USDC (FiatTokenV2)                         | USDH, most ERC20Permit tokens    |
| **Periphery function** | `depositWithAuthorization`                 | `depositWithPermit`              |

---

## Full end-to-end flow

```
1. User has tokens on HyperCore
2. User signs HL sendAsset → bot submits to HL API → tokens arrive on HyperEVM
3a. (EIP-3009) User signs receiveWithAuth → bot calls depositWithAuthorization
3b. (Permit)   User signs permit (one-time) → bot submits permit tx
                User signs depositData → bot calls depositWithPermit
4. SpokePool emits FundsDeposited event
5. Relayer fills on destination chain → user receives tokens
```

The user never needs native gas (HYPE) at any step.
