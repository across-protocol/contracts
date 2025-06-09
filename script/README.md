# Foundry Scripts

This directory contains Foundry scripts for various operations on the Across Protocol contracts.

## Migration Status

The migration from Hardhat to Foundry is in progress. We've successfully migrated all deployment scripts for the following components:

- Hub Pool and core protocol contracts
- Chain adapters for all supported chains (Arbitrum, Optimism, Base, Blast, etc.)
- Spoke pools for all supported chains
- Supporting utility contracts (Multicall, DAI Retriever, etc.)

## Directories

- **deployments/**: Contains deployment scripts that have been migrated from Hardhat to Foundry. See [deployments/README.md](./deployments/README.md) for details on how to use these scripts.
- **utils/**: Contains utility libraries like ChainUtils.sol for chain-specific constants
- Other scripts in this directory are for various operations like proxy deployments, contract interactions, etc.

## Usage

To run any script, use the following command:

```bash
forge script script/<script-path>.s.sol --rpc-url <RPC_URL> -vvvv
```

For scripts that modify state (deploy contracts, make transactions), add the `--broadcast` flag:

```bash
forge script script/<script-path>.s.sol --rpc-url <RPC_URL> --broadcast -vvvv
```

For contract verification, add the `--verify` flag:

```bash
forge script script/<script-path>.s.sol --rpc-url <RPC_URL> --broadcast --verify -vvvv
```
