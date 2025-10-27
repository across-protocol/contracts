# Constants Management System

This document explains how to use the new constants management system that uses a `constants.json` file instead of hardcoding values in the `Constants.sol` contract.

## Overview

The constants system consists of:

1. **`generated/constants.json`** - A structured JSON file containing all constants
2. **`script/utils/Constants.sol`** - The main constants contract that loads the constants from the JSON file
3. **`script/utils/GenerateConstantsJson.ts`** - A TypeScript script that generates the `constants.json` file

## File Structure

```
├── generated/constants.json          # All constants in JSON format
├── script/utils/
│   ├── Constants.sol                 # Main constants contract
│   └── CONSTANTS_README.md           # This documentation
```

## Using the Constants System

### 1. Reading from constants.json in Foundry Scripts

You can use Foundry's `vm.parseJson*` functions to read constants directly from the JSON file:

```solidity
// Deploy script needs to inherit DeploymentUtils.sol
uint256 cctpV2TokenMessenger = getL1Addresses(chainId).cctpV2TokenMessenger;
address weth = getWETHAddress(chainId);
```

### 2. Adding New Constants

To add a new constant, the `GenerateConstantsJson.ts` script needs to be updated to include the new constant.

```typescript
// Add the new constant to the GenerateConstantsJson.ts script
const constants = {
    PUBLIC_NETWORKS: convertChainFamiliesEnumString(),
    ...
    "newConstant": "newConstantValue",
  };
```

Then, run the `GenerateConstantsJson.ts` script to generate the `constants.json` file.

```bash
yarn generate-constants-json
```
