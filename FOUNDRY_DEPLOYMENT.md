# Foundry Deployment Guide

This document provides guidance on deploying Across protocol contracts using Foundry instead of Hardhat.

## Overview

The Across protocol has migrated from Hardhat to Foundry for deployment scripts. Foundry provides several advantages:

- Faster execution
- Better debugging
- Native Solidity scripting
- Improved gas reporting and optimization

All deployment scripts are located in the `script/deployments` directory and follow a consistent pattern.

## Prerequisites

1. Install Foundry:

   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

2. Create an `.env` file based on `.env.example`:

   ```bash
   cp .env.example .env
   ```

3. Edit the `.env` file with your specific configuration:
   - Add your secure mnemonic or private key
   - Add RPC URLs for chains you will deploy to
   - Add Etherscan API keys for contract verification
   - Configure any other required parameters

## Deployment Scripts

### Script Structure

All deployment scripts follow a similar structure:

1. **Imports**: Required dependencies including the contract to be deployed.
2. **Contract Definition**: The script is defined as a Forge script that inherits from ChainUtils.
3. **Constants**: Any constants needed for the deployment.
4. **Run Function**: The main function that performs the deployment.
5. **Helper Functions**: Any additional utility functions needed.

### Deployment Process

The basic deployment flow is:

1. **Configuration**: Load environment variables and set up configuration.
2. **Address Resolution**: Resolve chain-specific addresses for tokens and contracts.
3. **Deployment**: Deploy the contract with appropriate parameters.
4. **Proxy Setup**: For upgradeable contracts, deploy and initialize a proxy.
5. **Verification**: Automatically verify the contract on Etherscan if API key is provided.

### Deterministic Deployments

Some contracts require deterministic deployment to ensure they have the same address across different chains. We use the CREATE2 opcode for this purpose, replicating the functionality from hardhat-deploy:

1. **DeterministicDeployer**: Used to deploy contracts deterministically with CREATE2.
2. **CREATE2 Factory**: We use the same factory address (0x4e59b44847b379578588920ca78fbf26c0b4956c) as hardhat-deploy.
3. **Salt**: Each contract type has a specific salt value (e.g., "0x1234" for PolygonTokenBridger and SpokePoolVerifier, "0x12345678" for MulticallHandler).

Deterministic deployment is used for contracts that need the same address on multiple chains, such as:

- **PolygonTokenBridger**: Deployed with the same address on Ethereum and Polygon.
- **SpokePoolVerifier**: Deployed with the same address across all chains.
- **MulticallHandler**: Deployed with the same address on all EVM-compatible chains.

### Example Deployment

To deploy the HubPool contract to Ethereum mainnet:

```bash
# Load environment variables
source .env

# Deploy HubPool on mainnet
forge script script/deployments/DeployHubPool.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vvvv
```

For a spoke pool on an L2 chain (e.g., Optimism):

```bash
# Deploy Optimism SpokePool on Optimism
forge script script/deployments/DeployOptimismSpokePool.s.sol --rpc-url $OPTIMISM_RPC_URL --broadcast --verify -vvvv
```

## Chain-Specific Deployments

### Multi-Chain Pattern

The Across protocol operates across multiple chains, requiring coordinated deployments:

1. **Hub Pool**: Deployed on Ethereum mainnet (Layer 1).
2. **Chain Adapters**: Deployed on Ethereum mainnet, one for each supported L2.
3. **Spoke Pools**: Deployed on each L2 chain and connected to the Hub Pool.

### Address Management

Chain-specific addresses are managed in `script/utils/ChainUtils.sol`, which provides:

- Token addresses (WETH, USDC, etc.) for each chain
- Protocol contract addresses for each chain
- Helper functions for address resolution

## Testing Deployment Scripts

Before executing on actual networks, test your deployments:

```bash
# Test a specific deployment script on a forked network
./script/deployments/test-core-deployments.sh

# Test all deployment scripts
./script/deployments/test-deployments.sh
```

## Troubleshooting

### Common Issues

1. **RPC Connection Errors**: Ensure RPC URLs are correct and the service is available.
2. **Gas Estimation Failures**: The deployment might require more gas than estimated. Try increasing the gas limit.
3. **Address Checksum Errors**: Ensure addresses use the correct Ethereum checksum format.
4. **Initialization Errors**: For upgradeable contracts, ensure initialization parameters are correct.

### Chain-Specific Issues

1. **Blast Chain**: For testing Blast deployments, set `TESTING_MODE=true` to skip initialization.
2. **ZkSync Chain**: ZkSync deployments require special handling due to the custom ZkSync VM.

## Migration from Hardhat

If you're familiar with the previous Hardhat deployment scripts:

1. The `deploy/` directory contains the original Hardhat scripts.
2. The `script/deployments/` directory contains the new Foundry scripts.
3. Each Hardhat script has a corresponding Foundry script with the same functionality.

### Key Differences

- Foundry scripts are written in Solidity instead of TypeScript
- Configuration uses environment variables instead of Hardhat config
- Contract verification is handled by Forge's `--verify` flag

## Conclusion

The Foundry deployment scripts provide a more efficient and native way to deploy the Across protocol contracts. By following this guide, you should be able to successfully deploy the contracts to any supported chain.
