# Foundry Address Extraction Scripts

This directory contains the address extraction flow for Foundry deployments.

## Files

- `extract_foundry_addresses.sh` - Shell entrypoint used by `yarn extract-addresses`
- `ExtractDeployedFoundryAddresses.ts` - Scans tracked Foundry broadcasts and legacy addresses, then regenerates outputs
- `DeployedAddresses.sol` - Foundry-only JSON lookup helper for scripts and tests
- `../../broadcast/deployed-addresses.json` - Generated source of truth for deployed EVM addresses
- `../../broadcast/deployed-addresses.md` - Generated readable address listing

## Usage

```bash
yarn extract-addresses
```

Basic lookup:

```solidity
DeployedAddresses.getAddress(sepoliaChainId, "HubPool");
```

## How It Works

1. The script scans the `broadcast/` directory for `run-latest.json` files
2. It also reads from `deployments/legacy-addresses.json` for additional contract addresses
3. It extracts contract addresses from each file's transaction data
4. It organizes the data by chain ID and contract name
5. It generates the three output files with the extracted information
6. The Solidity contract uses Foundry's `parseJson` functionality to read addresses dynamically from the JSON file
7. All addresses are properly formatted using EIP-55 checksum for Solidity compatibility

## Important Notes

- Run the extraction script after each deployment to keep the addresses up to date
- The script only processes the latest deployment for each script/chain combination
- `DeployedAddresses.sol` only works in Foundry scripts and tests; it cannot be deployed on-chain because it uses `vm` cheatcodes
- The contract reads addresses dynamically from the JSON file, so it always reflects the latest data
- All addresses are properly checksummed using EIP-55 format for Solidity compatibility
- Non-Ethereum addresses (like Solana addresses) are filtered out for the Solidity contract
