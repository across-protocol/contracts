# Across Protocol Smart Contracts

This repository contains production smart contracts for the Across Protocol cross-chain bridge.

## Development Frameworks

- **Foundry** (primary) - Used for new tests and deployment scripts
- **Hardhat** (legacy) - Some tests still use Hardhat; we're migrating to Foundry

## Project Structure

```
contracts/           # Smart contract source files
  chain-adapters/    # L1 chain adapters
  interfaces/        # Interface definitions
  libraries/         # Shared libraries
test/evm/
  foundry/           # Foundry tests (.t.sol)
    local/           # Local unit tests
    fork/            # Fork tests
  hardhat/           # Legacy Hardhat tests (.ts)
script/              # Foundry deployment scripts (.s.sol)
  utils/             # Script utilities (Constants.sol, DeploymentUtils.sol)
lib/                 # External dependencies (git submodules)
```

## Build & Test Commands

```bash
# Build contracts
forge build                           # Foundry
yarn build-evm                        # Hardhat

# Run tests
yarn test-evm-foundry                 # Foundry local tests (recommended)
FOUNDRY_PROFILE=local forge test      # Same as above
yarn test-evm-hardhat                 # Hardhat tests (legacy)

# Run specific Foundry tests
forge test --match-test testDeposit
forge test --match-contract Router_Adapter
forge test -vvv                       # Verbose output
```

## Naming Conventions

### Contract Files

- PascalCase with underscores for chain-specific: `Arbitrum_SpokePool.sol`, `OP_Adapter.sol`
- Interfaces: `I` prefix: `ISpokePool.sol`, `IArbitrumBridge.sol`
- Libraries: `<Name>Lib.sol`

### Test Files

- Foundry: `.t.sol` suffix: `Router_Adapter.t.sol`, `Arbitrum_Adapter.t.sol`
- Test contracts: `contract <Name>Test is Test { ... }`
- Test functions: `function test<Description>() public`

### Deployment Scripts

- Numbered with `.s.sol` suffix: `001DeployHubPool.s.sol`, `004DeployArbitrumAdapter.s.sol`
- Script contracts: `contract Deploy<ContractName> is Script, Test, Constants`

## Writing Tests

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MyContract } from "../contracts/MyContract.sol";

contract MyContractTest is Test {
  MyContract public myContract;

  function setUp() public {
    myContract = new MyContract();
  }

  function testBasicFunctionality() public {
    // Test implementation
    assertEq(myContract.value(), expected);
  }
  function testRevertOnInvalidInput() public {
    vm.expectRevert();
    myContract.doSomething(invalidInput);
  }
}
```

### Test Gotchas

- **Mocks**: Check `contracts/test/` for existing mocks before creating new ones (MockCCTP.sol, ArbitrumMocks.sol, etc.)
- **MockSpokePool**: Requires UUPS proxy deployment: `new ERC1967Proxy(address(new MockSpokePool(weth)), abi.encodeCall(MockSpokePool.initialize, (...)))`
- **vm.mockCall pattern** (prefer over custom mocks for simple return values):
  ```solidity
  vm.etch(fakeAddr, hex"00");  // Bypass extcodesize check
  vm.mockCall(fakeAddr, abi.encodeWithSelector(SELECTOR), abi.encode(returnVal));
  vm.expectCall(fakeAddr, msgValue, abi.encodeWithSelector(SELECTOR, arg1));
  ```
- **Delegatecall context**: Adapter tests via HubPool emit events from HubPool's address; `vm.expectRevert()` may lose error data

## Deployment Scripts

Scripts follow a numbered pattern and use shared utilities from `script/utils/`.

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Constants } from "./utils/Constants.sol";
import { MyContract } from "../contracts/MyContract.sol";
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/00XDeployMyContract.s.sol:DeployMyContract --rpc-url $NODE_URL_1 -vvvv
// 3. Verify simulation works
// 4. Deploy: forge script script/00XDeployMyContract.s.sol:DeployMyContract --rpc-url $NODE_URL_1 --broadcast --verify -vvvv
contract DeployMyContract is Script, Test, Constants {
  function run() external {
    string memory deployerMnemonic = vm.envString("MNEMONIC");
    uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

    uint256 chainId = block.chainid;
    // Validate chain if needed
    require(chainId == getChainId("MAINNET"), "Deploy on mainnet only");

    vm.startBroadcast(deployerPrivateKey);

    MyContract myContract = new MyContract /* constructor args */();

    console.log("Chain ID:", chainId);
    console.log("MyContract deployed to:", address(myContract));

    vm.stopBroadcast();
  }
}
```

For upgradeable contracts, use `DeploymentUtils` which provides `deployNewProxy()`.

## Configuration

See `foundry.toml` for Foundry configuration. Key settings:

- Source: `contracts/`
- Tests: `test/evm/foundry/`
- Solidity: 0.8.30
- EVM: Prague
- Optimizer: 800 runs with via-ir

**Do not modify `foundry.toml` without asking** - explain what you want to change and why.

## Security Practices

- Follow CEI (Checks-Effects-Interactions) pattern
- Use OpenZeppelin for access control and upgrades
- Validate all inputs at system boundaries
- Use `_requireAdminSender()` for admin-only functions
- UUPS proxy pattern for upgradeable contracts
- Cross-chain ownership: HubPool owns all SpokePool contracts

## Linting

```bash
yarn lint-solidity    # Solhint for Solidity
yarn lint-js          # Prettier for JS/TS
yarn lint-fix         # Auto-fix all
```

## License

BUSL-1.1 (see LICENSE file for exceptions)
