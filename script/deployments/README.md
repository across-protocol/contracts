# Foundry Deployment Scripts

This directory contains Foundry deployment scripts for the Across Protocol contracts. These scripts replace the previous Hardhat deployment workflow.

## Migration Status

The migration from Hardhat to Foundry deployment scripts is in progress. We have implemented the following deployment scripts:

### Core Protocol Contracts

- [x] DeployHubPool.s.sol
- [x] DeployConfigStore.s.sol
- [x] DeploySpokePoolVerifier.s.sol
- [x] DeployBondToken.s.sol

### Chain Adapters

- [x] DeployArbitrumAdapter.s.sol
- [x] DeployOptimismAdapter.s.sol
- [x] DeployEthereumAdapter.s.sol
- [x] DeployBaseAdapter.s.sol
- [x] DeployPolygonAdapter.s.sol
- [x] DeployBlastAdapter.s.sol
- [x] DeployBlastRescueAdapter.s.sol
- [x] And 20+ additional chain adapters

### Spoke Pools

- [x] DeployArbitrumSpokePool.s.sol
- [x] DeployOptimismSpokePool.s.sol
- [x] DeployEthereumSpokePool.s.sol
- [x] DeployBaseSpokePool.s.sol
- [x] DeployBlastSpokePool.s.sol
- [x] And 20+ additional spoke pool deployments

### Utility Contracts

- [x] DeployMulticall3.s.sol
- [x] DeployBlastDaiRetriever.s.sol
- [x] And 10+ additional utility contracts

## Testing Scripts

- `test-deployments.sh`: Tests all deployment scripts on appropriate forked networks
- `test-blast-deployments.sh`: Tests only Blast-related deployment scripts

## Setup

Before using the deployment scripts, make sure you have Foundry installed and set up:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Environment Variables

Create a `.env` file in the root directory with the following variables:

```
# RPC URLs
MAINNET_RPC_URL=https://mainnet.infura.io/v3/your-api-key
OPTIMISM_RPC_URL=https://optimism-mainnet.infura.io/v3/your-api-key
ARBITRUM_RPC_URL=https://arbitrum-mainnet.infura.io/v3/your-api-key
# ... add other chain RPC URLs as needed

# Deploy mnemonic
MNEMONIC="your twelve word mnemonic here"

# Verification
ETHERSCAN_API_KEY=your-etherscan-api-key
```

## Using the Scripts

### Loading Environment Variables

You must first load your environment variables:

```bash
source .env
```

### Deployment Commands

To deploy a contract, run the following command:

```bash
# Test the script in simulation mode (no actual transactions)
forge script script/deployments/DeployHubPool.s.sol --rpc-url $MAINNET_RPC_URL -vvvv

# Deploy and verify the contract
forge script script/deployments/DeployHubPool.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vvvv
```

For multi-chain deployments, you need to specify the appropriate RPC URL:

```bash
# Deploy Optimism adapter on mainnet
forge script script/deployments/DeployOptimismAdapter.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vvvv

# Deploy Optimism spoke pool on Optimism
forge script script/deployments/DeployOptimismSpokePool.s.sol --rpc-url $OPTIMISM_RPC_URL --broadcast --verify -vvvv
```

## Contract Dependencies

Some contracts need the addresses of previously deployed contracts. There are two approaches to handle this:

### 1. Via Environment Variables

Set the deployed contract addresses as environment variables:

```bash
export HUB_POOL_ADDRESS=0x... # Address of the deployed HubPool
```

### 2. Via Deployment Artifacts

The scripts can also read from deployment artifacts:

```bash
# Export the address after deployment
export HUB_POOL_ADDRESS=$(jq -r '.transactions[] | select(.contractName=="HubPool") | .contractAddress' broadcast/deployments/DeployHubPool.s.sol/1/run-latest.json)
```

## Chain Constants

Contract deployment parameters, including addresses of external contracts and tokens, are defined in the `utils/ChainUtils.sol` file. This file contains the mappings for:

- Chain-specific addresses (WETH, USDC, etc.)
- Protocol-specific addresses (finders, bridges, etc.)
- Cross-chain messaging protocol addresses

## Deterministic Deployments

Some contracts in the Across protocol require deployment at the same address across multiple chains. We use the CREATE2 opcode for this, implemented in `utils/DeterministicDeployer.sol`. This replicates the functionality in hardhat-deploy:

1. We use the same CREATE2 factory address (0x4e59b44847b379578588920ca78fbf26c0b4956c)
2. We use the same salt values for each contract type:
   - "0x1234" for PolygonTokenBridger and SpokePoolVerifier
   - "0x12345678" for MulticallHandler

The deployed contracts will have the same address regardless of whether Hardhat or Foundry is used for deployment.

This is crucial for contracts like:

- **PolygonTokenBridger**: Must have identical addresses on both L1 and L2 for cross-chain messaging
- **SpokePoolVerifier**: Benefits from having a consistent address across all chains
- **MulticallHandler**: Deployed at the same address on all EVM-compatible chains (except ZkSync and Linea which aren't fully EVM equivalent)

## Deployment Sequence

For a new deployment, follow this sequence:

1. Deploy LpTokenFactory and HubPool on Ethereum:

   ```
   forge script script/deployments/DeployHubPool.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vvvv
   ```

2. Deploy chain adapters on Ethereum (e.g., Optimism adapter):

   ```
   forge script script/deployments/DeployOptimismAdapter.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify -vvvv
   ```

3. Deploy spoke pools on respective chains:
   ```
   forge script script/deployments/DeployOptimismSpokePool.s.sol --rpc-url $OPTIMISM_RPC_URL --broadcast --verify -vvvv
   ```

## Maintaining Deployments

After deployment, information about deployed contracts is stored in the `broadcast` directory. You can save these files to track deployed contract addresses.

Alternatively, you can create a deployments record file manually to keep track of deployed addresses across all chains.
