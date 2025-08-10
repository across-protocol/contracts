# Constants Management System

This document explains how to use the new constants management system that uses a `constants.json` file instead of hardcoding values in the `Constants.sol` contract.

## Overview

The constants system consists of:

1. **`constants.json`** - A structured JSON file containing all constants
2. **`script/Constants.sol`** - The main constants contract with hardcoded values for compatibility
3. **`script/ConstantsLoader.s.sol`** - A Foundry script demonstrating how to use `parseJson` functions

## File Structure

```
├── constants.json                    # All constants in JSON format
├── script/
│   ├── Constants.sol                 # Main constants contract
│   └── ConstantsLoader.s.sol         # Example script using parseJson
└── CONSTANTS_README.md               # This documentation
```

## Using the Constants System

### 1. Reading from constants.json in Foundry Scripts

You can use Foundry's `vm.parseJson*` functions to read constants directly from the JSON file:

```solidity
// Load chain IDs
uint256 mainnetChainId = vm.parseJsonUint("constants.json", ".chainIds.MAINNET");
uint256 arbitrumChainId = vm.parseJsonUint("constants.json", ".chainIds.ARBITRUM");

// Load addresses
address mainnetWeth = vm.parseJsonAddress("constants.json", ".wrappedNativeTokens.MAINNET");
address arbitrumL2Router = vm.parseJsonAddress("constants.json", ".l2Addresses.ARBITRUM.l2GatewayRouter");

// Load time constants
uint256 quoteTimeBuffer = vm.parseJsonUint("constants.json", ".timeConstants.QUOTE_TIME_BUFFER");
```

### 2. Available JSON Paths

The `constants.json` file is organized into the following sections:

#### Chain IDs

```json
{
  "chainIds": {
    "MAINNET": 1,
    "ARBITRUM": 42161,
    "OPTIMISM": 10
    // ... more chains
  }
}
```

#### Wrapped Native Tokens

```json
{
  "wrappedNativeTokens": {
    "MAINNET": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "ARBITRUM": "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"
    // ... more tokens
  }
}
```

#### L2 Addresses

```json
{
  "l2Addresses": {
    "ARBITRUM": {
      "l2GatewayRouter": "0x5288c571Fd7aD117beA99bF60FE0846C4E84F933",
      "cctpTokenMessenger": "0x19330d10D9Cc8751218eaf51E8885D058642E08A",
      "uniswapV3SwapRouter": "0xE592427A0AEce92De3Edee1F18E0157C05861564"
    }
  }
}
```

#### L1 Addresses

```json
{
  "l1Addresses": {
    "MAINNET": {
      "finder": "0x40f941E48A552bF496B154Af6bf55725f18D77c3",
      "l1ArbitrumInbox": "0x4Dbd4fc535Ac27206064B68FfCf827b0A60BAB3f"
      // ... more addresses
    }
  }
}
```

#### OP Stack Addresses

```json
{
  "opStackAddresses": {
    "MAINNET": {
      "BASE": {
        "L1CrossDomainMessenger": "0x866E82a600A1414e583f7F13623F1aC5d58b0Afa",
        "L1StandardBridge": "0x3154Cf16ccdb4C6d922629664174b904d80F2C35"
      }
    }
  }
}
```

#### Circle Domain IDs

```json
{
  "circleDomainIds": {
    "MAINNET": 0,
    "ARBITRUM": 3,
    "OPTIMISM": 2
  }
}
```

#### Time Constants

```json
{
  "timeConstants": {
    "QUOTE_TIME_BUFFER": 3600,
    "FILL_DEADLINE_BUFFER": 21600
  }
}
```

### 3. Running the Example Script

To see the constants system in action, run the example script:

```bash
forge script script/ConstantsLoader.s.sol:ConstantsLoader --rpc-url <your-rpc-url>
```

This will:

- Load constants from `constants.json`
- Display them in the console
- Compare them with hardcoded values in `Constants.sol`
- Verify they match

### 4. Adding New Constants

To add new constants:

1. **Add to `constants.json`**:

   ```json
   {
     "chainIds": {
       "NEW_CHAIN": 12345
     },
     "wrappedNativeTokens": {
       "NEW_CHAIN": "0x..."
     }
   }
   ```

2. **Add to `Constants.sol`** (for compatibility):

   ```solidity
   uint256 constant NEW_CHAIN = 12345;
   WETH9Interface constant WRAPPED_NATIVE_TOKEN_NEW_CHAIN = WETH9Interface(0x...);
   ```

3. **Use in scripts**:
   ```solidity
   uint256 newChainId = vm.parseJsonUint("constants.json", ".chainIds.NEW_CHAIN");
   address newChainWeth = vm.parseJsonAddress("constants.json", ".wrappedNativeTokens.NEW_CHAIN");
   ```

## Benefits

1. **Single Source of Truth**: All constants are defined in one JSON file
2. **Easy Updates**: Modify constants without touching Solidity code
3. **Type Safety**: Foundry's `parseJson*` functions provide type safety
4. **Backward Compatibility**: The `Constants.sol` contract still works as before
5. **Flexibility**: Can load constants dynamically in scripts

## Best Practices

1. **Always keep JSON and Solidity in sync** when adding new constants
2. **Use descriptive JSON paths** for easy navigation
3. **Validate constants** by comparing JSON values with hardcoded values
4. **Use try-catch blocks** when loading optional constants
5. **Document new constants** in both JSON and Solidity files

## Example Usage in Deployment Scripts

```solidity
contract MyDeploymentScript is Script {
  function run() public {
    // Load constants for the target chain
    uint256 chainId = vm.parseJsonUint("constants.json", ".chainIds.MAINNET");
    address weth = vm.parseJsonAddress("constants.json", ".wrappedNativeTokens.MAINNET");

    // Load L1 addresses
    address finder = vm.parseJsonAddress("constants.json", ".l1Addresses.MAINNET.finder");
    address arbitrumInbox = vm.parseJsonAddress("constants.json", ".l1Addresses.MAINNET.l1ArbitrumInbox");

    // Use constants in deployment
    // ... deployment logic
  }
}

```

This system provides a clean, maintainable way to manage constants across your Foundry project while maintaining backward compatibility with existing code.
