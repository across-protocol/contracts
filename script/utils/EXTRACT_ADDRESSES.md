# Foundry Address Extraction Scripts

This directory contains scripts to extract deployed contract addresses from Foundry broadcast files and generate useful artifacts for use in other deployment scripts.

## Prerequisites

The extraction script requires Node.js and TypeScript support.

### Installation

```bash
# Install dependencies (if not already installed)
yarn install


```

## Files

- `extract_foundry_addresses.sh` - Bash script to run the extraction process
- `ExtractDeployedFoundryAddresses.ts` - TypeScript script that does the actual extraction
- `DeployedAddresses.sol` - Solidity contract with all deployed addresses

## Usage

### Running the Script

```bash
# Using yarn (recommended)
yarn extract-addresses


# Or run the bash script directly
./script/extract_foundry_addresses.sh
```

### Generated Output

The script generates three files:

1. **`broadcast/deployed-addresses.md`** - Human-readable markdown file with all deployed addresses
2. **`broadcast/deployed-addresses.json`** - Structured JSON data with all deployed addresses

### Using DeployedAddresses.sol in Your Scripts

The `DeployedAddresses.sol` contract uses Foundry's `parseJson` functionality to dynamically read addresses from the JSON file. This approach is **only for use in Foundry scripts and tests** (not for on-chain deployment).

#### Basic Usage

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Script } from "forge-std/Script.sol";
import { DeployedAddresses } from "./DeployedAddresses.sol";

contract MyDeploymentScript is Script {
  function run() external {
    uint256 sepoliaChainId = 11155111;

    // Get addresses dynamically by chain ID and contract name
    address hubPool = DeployedAddresses.getAddress(sepoliaChainId, "HubPool");
    address lpTokenFactory = DeployedAddresses.getAddress(sepoliaChainId, "LpTokenFactory");

    // Check if a contract exists before using it
    if (DeployedAddresses.hasAddress(sepoliaChainId, "HubPool")) {
      // Contract exists, safe to use
      address hubPoolAddress = DeployedAddresses.getAddress(sepoliaChainId, "HubPool");
    }

    // Get additional contract information
    (address addr, string memory txHash, uint256 blockNum) = DeployedAddresses.getContractInfo(
      sepoliaChainId,
      "HubPool"
    );
  }
}
```

### Available Functions

The `DeployedAddresses` contract provides these functions:

#### `getAddress(uint256 chainId, string memory contractName)`

- Returns the contract address for the given chain ID and contract name
- Returns `address(0)` if the contract doesn't exist
- **View function** - no gas cost for reading
- Uses Foundry's `vm.readFile` and `stdJson` to read from the JSON file

#### `hasAddress(uint256 chainId, string memory contractName)`

- Returns `true` if a contract exists for the given chain ID and name
- Returns `false` if the contract doesn't exist
- **View function** - no gas cost for reading

#### `getTransactionHash(uint256 chainId, string memory contractName)`

- Returns the transaction hash for the contract deployment
- Returns empty string if not available

#### `getBlockNumber(uint256 chainId, string memory contractName)`

- Returns the block number where the contract was deployed
- Returns `0` if not available

#### `getChainName(uint256 chainId)`

- Returns the human-readable name for the given chain ID
- Returns empty string if chain ID is not recognized

#### `getContractNames(uint256 chainId)`

- Returns an array of all contract names deployed on the given chain
- Returns empty array if no contracts found

#### `getChainIds()`

- Returns an array of all chain IDs that have deployed contracts

#### `getGeneratedAt()`

- Returns the timestamp when the JSON file was generated

#### `getContractInfo(uint256 chainId, string memory contractName)`

- Returns a tuple with (address, transactionHash, blockNumber) for the contract
- Convenience function to get all info at once

### Contract Name for Dynamic Lookup

For the `getAddress()` and `hasAddress()` functions, use the original contract name as it appears in the deployment:

Examples:

- `"HubPool"` - for the HubPool contract
- `"LpTokenFactory"` - for the LpTokenFactory contract
- `"PermissionSplitterProxy"` - for the PermissionSplitterProxy contract
- `"SpokePool"` - for the SpokePool contract

### Chain Support

The script recognizes these chains:

- Mainnet (Chain ID: 1)
- Sepolia (Chain ID: 11155111)
- Arbitrum One (Chain ID: 42161)
- Arbitrum Sepolia (Chain ID: 421614)
- Polygon (Chain ID: 137)
- Polygon Amoy (Chain ID: 80002)
- Optimism (Chain ID: 10)
- Unichain (Chain ID: 130)
- Optimism Sepolia (Chain ID: 11155420)
- Base (Chain ID: 8453)
- Base Sepolia (Chain ID: 84532)
- BSC (Chain ID: 56)
- Lens (Chain ID: 232)
- Boba (Chain ID: 288)
- zkSync Era (Chain ID: 324)
- World Chain (Chain ID: 480)
- Redstone (Chain ID: 690)
- Lisk (Chain ID: 1135)
- Lisk Sepolia (Chain ID: 4202)
- Unichain Sepolia (Chain ID: 1301)
- Soneium (Chain ID: 1868)
- Linea (Chain ID: 59144)
- Scroll (Chain ID: 534352)
- Scroll Sepolia (Chain ID: 534351)
- Blast (Chain ID: 81457)
- Blast Sepolia (Chain ID: 168587773)
- Mode (Chain ID: 34443)
- Mode Testnet (Chain ID: 919)
- Lens Testnet (Chain ID: 37111)
- Aleph Zero (Chain ID: 41455)
- Ink (Chain ID: 57073)
- Tatara Testnet (Chain ID: 129399)
- BOB Sepolia (Chain ID: 808813)
- Zora (Chain ID: 7777777)
- Solana (Chain ID: 34268394551451)
- Solana Devnet (Chain ID: 133268194659241)

## How It Works

1. The script scans the `broadcast/` directory for `run-latest.json` files
2. It also reads from `deployments/deployments.json` for additional contract addresses
3. It extracts contract addresses from each file's transaction data
4. It organizes the data by chain ID and contract name
5. It generates the three output files with the extracted information
6. The Solidity contract uses Foundry's `parseJson` functionality to read addresses dynamically from the JSON file
7. All addresses are properly formatted using EIP-55 checksum for Solidity compatibility

## Important Notes

- Run the extraction script after each deployment to keep the addresses up to date
- The script only processes the latest deployment for each script/chain combination
- **The contract only works in Foundry scripts and tests** - it cannot be deployed on-chain due to the use of `vm` cheatcodes
- The contract reads addresses dynamically from the JSON file, so it always reflects the latest data
- All addresses are properly checksummed using EIP-55 format for Solidity compatibility
- Non-Ethereum addresses (like Solana addresses) are filtered out for the Solidity contract
