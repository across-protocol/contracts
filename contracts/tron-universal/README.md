# Tron Universal Contracts

Tron-compatible forks of contracts that cannot compile with Tron's solc (0.8.25). These exist solely to work around Tron solc limitations — the on-chain behavior is identical to the original contracts.

## Why these forks exist

Tron's Solidity compiler supports up to **solc 0.8.25**. Two incompatibilities prevent the original contracts from compiling:

### 1. SP1HeliosTron

**Original:** `contracts/sp1-helios/SP1Helios.sol` (pragma `^0.8.30`)

**Issue:** `require` with custom errors (e.g. `require(condition, CustomError(arg))`) was introduced in **Solidity 0.8.26**. SP1Helios uses this syntax in 7 places.

**Fix:** Replace all `require(condition, CustomError(...))` with `if (!condition) revert CustomError(...)`. This is semantically identical — both revert with the same custom error selector and arguments.

### 2. SpokePoolTron / Universal_SpokePoolTron

**Original:** `contracts/SpokePool.sol` and `contracts/Universal_SpokePool.sol`

**Issue:** `SpokePool.sol` has two `using ... for address` directives in scope that both define `isContract`:

- `using AddressLibUpgradeable for address` (line 46 of SpokePool.sol)
- `using AddressUpgradeable for address` (line 20 of SafeERC20Upgradeable.sol, pulled in via `using SafeERC20Upgradeable for IERC20Upgradeable`)

On solc >=0.8.26, the compiler resolves this correctly since both functions have identical signatures. On solc 0.8.25, the compiler treats this as an ambiguity error: `Member "isContract" not unique after argument-dependent lookup in address`.

**Fix:** Replace the two `addr.isContract()` calls in SpokePool with explicit `AddressLibUpgradeable.isContract(addr)`. This disambiguates the call for the older compiler. `Universal_SpokePoolTron` then inherits from `SpokePoolTron` instead of `SpokePool`.

## Foundry profile

These contracts are compiled with the `tron-universal` Foundry profile:

```bash
FOUNDRY_PROFILE=tron-universal forge build
```

This profile uses `bin/solc-tron` (solc 0.8.25) and outputs artifacts to `out-tron-universal/`.

## Keeping forks in sync

When `SP1Helios.sol`, `SpokePool.sol`, or `Universal_SpokePool.sol` are updated, the corresponding Tron fork must be updated to match. The forks are intentionally minimal — only the lines listed above differ from the originals.
