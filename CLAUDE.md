# Across Protocol Smart Contracts

This repository contains production smart contracts for the Across Protocol cross-chain bridge.

## Architecture

Across uses a **hub-and-spoke** model with optimistic verification to enable fast cross-chain token transfers.

### Core Contracts

- **HubPool** (Ethereum L1) — Central contract that manages LP liquidity, validates cross-chain transfers via merkle root bundles, and coordinates rebalancing across all SpokePools. Uses UMA's Optimistic Oracle for dispute resolution.
- **SpokePool** (each L2/sidechain) — Deployed on every supported chain. Handles user deposits, relayer fills, and execution of merkle leaves (relayer refunds, slow fills). UUPS upgradeable. Chain-specific variants (e.g. `Arbitrum_SpokePool`, `Optimism_SpokePool`) override admin verification and bridge-specific logic.
- **Chain Adapters** (`contracts/chain-adapters/`) — Stateless contracts called via `delegatecall` from HubPool to bridge tokens and relay messages to each L2. Each adapter wraps a chain's native bridge (Arbitrum Inbox, OP Stack messenger, Polygon FxPortal, etc.). Also supports CCTP, LayerZero OFT, and Wormhole.

### Key Roles

| Role | Description |
|------|-------------|
| **Depositor** | End user (non-technical) who initiates a cross-chain transfer via one of multiple entry points (deposit, sponsored, gasless flows) on the origin SpokePool |
| **Relayer** | Fills deposits on destination chain by fronting tokens, later reimbursed via merkle proof. Relayers compete on speed and cross-chain inventory management to determine if a deposit is profitable based on the fees offered |
| **Data Worker** | Off-chain agent that validates and aggregates deposits/fills across multiple chains, constructs merkle trees, and calls `proposeRootBundle()` on HubPool (stakes a bond). Unlike relayers, data workers are RPC-intensive and maintain a longer lookback window; speed is less critical |
| **Disputer** | Monitors proposed bundles; can call `disputeRootBundle()` during the challenge period if a bundle is invalid |
| **LP** | Deposits L1 tokens into HubPool to earn relay fees |

### Protocol Flow

1. **Deposit**: User locks tokens in origin SpokePool and sets the fee amount they're willing to pay to a relayer → `FundsDeposited` event emitted. Relayers evaluate profitability by comparing offered fees against their cost to fulfill the deposit (inventory, gas, slippage). Fair pricing is communicated via hosted API services or directly from exclusive relayers.
2. **Fill**: Relayer sees event, calls `fillRelay()` on destination SpokePool → tokens sent to recipient
3. **Bundle Proposal**: Data worker validates and aggregates fills across all chains into three merkle trees (pool rebalances, relayer refunds, slow fills) and proposes on HubPool
4. **Challenge Period**: Bundle is open for dispute (default 2 hours). If disputed, UMA oracle resolves
5. **Execution**: After liveness, `executeRootBundle()` sends tokens via adapters and relays roots to SpokePools
6. **Refund**: Relayers call `executeRelayerRefundLeaf()` with merkle proofs to claim repayment
7. **Slow Fill** (fallback): If no relayer fills before deadline, the protocol fills from SpokePool reserves via `executeSlowRelayLeaf()`

### Cross-Chain Ownership

HubPool on L1 owns all L2 SpokePools. Admin functions are relayed cross-chain via `relaySpokePoolAdminFunction()` through the appropriate chain adapter. Each SpokePool's `_requireAdminSender()` verifies the caller using chain-specific logic (address aliasing on Arbitrum, CrossDomainMessenger on OP Stack, etc.).

### Supported Chains

SpokePools exist for: Ethereum, Arbitrum, Optimism, Base, Polygon, Polygon zkEVM, zkSync, Scroll, Linea, Blast, Boba, Lisk, WorldChain, Ink, Lens, Mode, and others via `Universal_SpokePool` (generic OP Stack).

### Key Libraries

- **CircleCCTPAdapter** — USDC bridging via Circle's CCTP (V1/V2), with burn-limit splitting for large transfers
- **OFTTransportAdapter** — Token bridging via LayerZero OFT standard
- **MerkleLib** — Merkle proof verification with bitmap tracking to prevent double-claiming
- **Lockable** — Custom reentrancy guard used across SpokePools

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
yarn test-evm-foundry                 # Foundry local tests (recommended; uses FOUNDRY_PROFILE=local-test)
FOUNDRY_PROFILE=local-test forge test # Required for local Foundry tests in this repo
yarn test-evm-hardhat                 # Hardhat tests (legacy)

# Run specific Foundry tests
FOUNDRY_PROFILE=local-test forge test --match-test testDeposit
FOUNDRY_PROFILE=local-test forge test --match-contract Router_Adapter
FOUNDRY_PROFILE=local-test forge test -vvv # Verbose output
```

Use `FOUNDRY_PROFILE=local-test` (or `yarn test-evm-foundry`) for local Foundry test runs; do not use plain `forge test`.

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

## Code Style

**Prioritize succinctness.** Express features in the least lines possible. This often leads to the most elegant solution:

- Consolidate duplicate code paths (e.g., one function call with different parameters instead of multiple branches with similar calls)
- Compute values before branching, then use them in a single code path
- Avoid redundant intermediate variables when the expression is clear (although consider gas cost implications, especially for mainnet contracts)
- Prefer early returns to reduce nesting

## Linting

```bash
yarn lint-solidity    # Solhint for Solidity
yarn lint-js          # Prettier for JS/TS
yarn lint-fix         # Auto-fix all
```

## License

BUSL-1.1 (see LICENSE file for exceptions)
