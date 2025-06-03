# Foundry Deployment Templates

This directory contains templates for creating new Foundry deployment scripts. Use these templates as a starting point when creating deployment scripts for new contracts.

## Templates

### DeployGenericAdapter.s.sol

- Template for deploying L1 adapter contracts for various L2s
- Customizable for different L2 bridge protocols
- Example: Arbitrum_Adapter, Optimism_Adapter, etc.

### DeployGenericSpokePool.s.sol

- Template for deploying L2 spoke pool contracts
- Includes proxy deployment pattern for upgradeable contracts
- Example: Arbitrum_SpokePool, Optimism_SpokePool, etc.

### DeployUtilityContract.s.sol

- Template for deploying utility contracts
- Simple deployment pattern for non-upgradeable contracts
- Example: Multicall3, ERC1155, etc.

## Creating a New Deployment Script

1. Copy the appropriate template to the main `script/deployments` directory
2. Rename the file and contract to match your target contract
3. Update the imports to include your specific contract
4. Customize the deployment logic for your contract's constructor
5. Update the address lookups to match your contract's requirements
6. Test the script on a fork network before using it for production deployments

## Usage

See the [parent README.md](../README.md) for details on how to use these deployment scripts.
