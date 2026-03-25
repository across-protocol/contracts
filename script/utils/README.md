# Script Utils

Utilities in this directory support Foundry deployment scripts.

## Files

- `Constants.sol` - Foundry-side accessors over generated constants data
- `GenerateConstantsJson.ts` - Regenerates `generated/constants.json`
- `DeploymentUtils.sol` - Common deployment lookups and helpers used by scripts
- `extract_foundry_addresses.sh` - Shell entrypoint used by `yarn extract-addresses`
- `ExtractDeployedFoundryAddresses.ts` - Scans tracked Foundry broadcasts and legacy addresses, then regenerates outputs
- `DeployedAddresses.sol` - Foundry-only JSON lookup helper for scripts and tests
- `../../generated/constants.json` - Generated constants consumed by script utilities
- `../../broadcast/deployed-addresses.json` - Generated source of truth for deployed EVM addresses
- `../../broadcast/deployed-addresses.md` - Generated readable address listing

## Usage

```bash
yarn generate-constants-json
yarn extract-addresses
```

Basic lookups:

```solidity
address hubPool = DeployedAddresses.getAddress(sepoliaChainId, "HubPool");
address weth = getWETHAddress(chainId);
```

## How It Works

1. `GenerateConstantsJson.ts` regenerates `generated/constants.json` for script-side constant lookup.
2. `ExtractDeployedFoundryAddresses.ts` scans tracked `broadcast/` receipts and `deployments/legacy-addresses.json`.
3. Address extraction regenerates `broadcast/deployed-addresses.json`, `broadcast/deployed-addresses.md`, and `DeployedAddresses.sol`.
4. Foundry scripts and tests read these generated files through `Constants.sol`, `DeploymentUtils.sol`, and `DeployedAddresses.sol`.

## Important Notes

- Update generated files when deployment inputs or outputs change
- `DeployedAddresses.sol` only works in Foundry scripts and tests; it cannot be deployed on-chain because it uses `vm` cheatcodes
- Non-Ethereum addresses, such as Solana addresses, are filtered out of `DeployedAddresses.sol`
- If behavior is unclear, read the corresponding `.ts` or `.sol` implementation directly
