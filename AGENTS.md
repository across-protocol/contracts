# Across Protocol Smart Contracts

This repository contains production smart contracts for the Across Protocol cross-chain bridge, including EVM (Solidity) and SVM (Rust/Anchor) programs.

## How to use docs in this repo

Start with this file. If extra clarity is needed, read nearby local `.md` files, especially the closest `README.md`.

Read local READMEs when you need more detail. Useful examples can be found throughout the repo, including `script/utils/README.md`, `script/universal/README.md`, and `deployments/README.md`.

## Documentation maintenance

Keep docs updated in the same change whenever behavior, configuration, interfaces, or contract structure changes.

- Before writing implementation plans, surface material ambiguities first and resolve them with the user.
- For each new task, propose 0-3 targeted doc updates, or explicitly state why none are needed.

## Architecture

### Intents System (Hub-and-Spoke)

Across uses a **hub-and-spoke** model with optimistic verification to enable fast cross-chain token transfers. This is the core system the repo was historically built around.

#### Core Contracts

- **HubPool** (Ethereum L1) — Central contract that manages LP liquidity, validates cross-chain transfers via merkle root bundles, and coordinates rebalancing across all SpokePools. Uses UMA's Optimistic Oracle for dispute resolution.
- **SpokePool** (each L2/sidechain) — Deployed on every supported chain. Handles user deposits, relayer fills, and execution of merkle leaves (relayer refunds, slow fills). UUPS upgradeable. Chain-specific variants (e.g. `Arbitrum_SpokePool`, `Optimism_SpokePool`) override admin verification and bridge-specific logic.
- **Chain Adapters** (`contracts/chain-adapters/`) — Stateless contracts called via `delegatecall` from HubPool to bridge tokens and relay messages to each L2. Each adapter wraps a chain's native bridge (Arbitrum Inbox, OP Stack messenger, Polygon FxPortal, etc.). Also supports CCTP, LayerZero OFT, and Wormhole.

#### Key Roles

| Role            | Description                                                                                                                                                                                                                                                                             |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Depositor**   | End user (non-technical) who initiates a cross-chain transfer via one of multiple entry points (deposit, sponsored, gasless flows) on the origin SpokePool                                                                                                                              |
| **Relayer**     | Fills deposits on destination chain by fronting tokens, later reimbursed via merkle proof. Relayers compete on speed and cross-chain inventory management to determine if a deposit is profitable based on the fees offered                                                             |
| **Data Worker** | Off-chain agent that validates and aggregates deposits/fills across multiple chains, constructs merkle trees, and calls `proposeRootBundle()` on HubPool (stakes a bond). Unlike relayers, data workers are RPC-intensive and maintain a longer lookback window; speed is less critical |
| **Disputer**    | Monitors proposed bundles; can call `disputeRootBundle()` during the challenge period if a bundle is invalid                                                                                                                                                                            |
| **LP**          | Deposits L1 tokens into HubPool to earn relay fees                                                                                                                                                                                                                                      |

#### Protocol Flow

1. **Deposit**: User locks tokens in origin SpokePool and sets the fee amount they're willing to pay to a relayer → `FundsDeposited` event emitted. Relayers evaluate profitability by comparing offered fees against their cost to fulfill the deposit (inventory, gas, slippage). Fair pricing is communicated via hosted API services or directly from exclusive relayers.
2. **Fill**: Relayer sees event, calls `fillRelay()` on destination SpokePool → tokens sent to recipient
3. **Bundle Proposal**: Data worker validates and aggregates fills across all chains into three merkle trees (pool rebalances, relayer refunds, slow fills) and proposes on HubPool
4. **Challenge Period**: Bundle is open for dispute (default 2 hours). If disputed, UMA oracle resolves
5. **Execution**: After liveness, `executeRootBundle()` sends tokens via adapters and relays roots to SpokePools
6. **Refund**: Relayers call `executeRelayerRefundLeaf()` with merkle proofs to claim repayment
7. **Slow Fill** (fallback): If no relayer fills before deadline, the protocol fills from SpokePool reserves via `executeSlowRelayLeaf()`

#### Cross-Chain Ownership

HubPool on L1 owns all L2 SpokePools. Admin functions are relayed cross-chain via `relaySpokePoolAdminFunction()` through the appropriate chain adapter. Each SpokePool's `_requireAdminSender()` verifies the caller using chain-specific logic (address aliasing on Arbitrum, CrossDomainMessenger on OP Stack, etc.).

### Mint-Burn System

Located in `contracts/periphery/mintburn/`. A modular framework for executing cross-chain sponsored token flows using mint-burn bridge integrations (CCTP, LayerZero OFT). Off-chain signers authorize transfer parameters via signed quotes; source periphery contracts validate quotes and initiate bridge transfers, while destination handlers receive bridged tokens and execute on-chain actions (swaps, HyperCore transfers, or arbitrary multicalls). Bridge-specific peripheries live in `sponsored-cctp/` and `sponsored-oft/` subdirectories.

### Deployments

Canonical deployed addresses are generated into `broadcast/deployed-addresses.json`, with `broadcast/deployed-addresses.md` as the readable companion. `deployments/legacy-addresses.json` is still included for legacy Hardhat deployments. In Foundry scripts, use `script/utils/DeploymentUtils.sol` lookup helpers such as `getDeployedAddress()` and `getSpokePoolDeploymentInfo()`.

## Development Frameworks

- **Foundry** (primary) - Used for new tests and deployment scripts
- **Hardhat** (legacy) - Some tests still use Hardhat; we're migrating to Foundry

## Project Structure

```
contracts/           # Smart contract source files
  chain-adapters/    # L1 chain adapters (intents system)
  test/              # Mock contracts for testing
  periphery/         # Periphery contracts
    mintburn/        # Mint-burn system (sponsored CCTP, OFT flows)
  interfaces/        # Interface definitions
  libraries/         # Shared libraries
test/
  evm/foundry/       # Foundry tests (.t.sol)
    local/           # Local unit tests
    fork/            # Fork tests
    utils/           # Test base classes
  evm/hardhat/       # Legacy Hardhat tests (.ts)
  svm/               # Solana program tests
programs/            # Solana/Anchor programs
idls/                # Anchor IDL files
script/              # Foundry deployment scripts (.s.sol)
  utils/             # Script utilities and deployment docs
  universal/         # Universal SpokePool deployment
broadcast/           # Foundry deployment receipts and generated address artifacts
deployments/         # Legacy Hardhat addresses and deployment notes
lib/                 # External dependencies (git submodules)
```

## Build & Test Commands

```bash
yarn build-evm-foundry                # Foundry build
yarn test-evm-foundry                 # Foundry local tests (recommended)
yarn test-evm-foundry -- --match-test testDeposit
yarn test-evm-foundry -- --match-contract Router_Adapter
yarn test-evm-foundry -- -vvv         # Verbose output
yarn test-evm-hardhat                 # Hardhat tests (legacy)
```

Use `yarn test-evm-foundry` for local Foundry runs; it sets `FOUNDRY_PROFILE=local-test`. `yarn build-evm-foundry` can take up to 5 minutes.

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

- `.s.sol` suffix, see `script/` for examples (e.g. `script/DeployArbitrumAdapter.s.sol`)
- Script contracts: `contract Deploy<ContractName> is Script, Test, Constants`

## Writing Tests

See `test/evm/foundry/local/` for examples (e.g. `test/evm/foundry/local/Router_Adapter.t.sol`).

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

## Configuration

See `foundry.toml` for Foundry configuration. **Do not modify `foundry.toml` without asking.**

## Security Practices

- Follow CEI (Checks-Effects-Interactions) pattern
- Use OpenZeppelin for access control and upgrades
- Validate all inputs at system boundaries
- Use `_requireAdminSender()` for admin-only functions
- UUPS proxy pattern for upgradeable contracts
- Cross-chain ownership: HubPool owns all SpokePool contracts

## Code Style

Prioritize security, succinctness, and DRY code.

**Prioritize succinctness.** Express features in the least lines possible. This often leads to the most elegant solution:

- Consolidate duplicate code paths (e.g., one function call with different parameters instead of multiple branches with similar calls)
- Compute values before branching, then use them in a single code path
- Reuse existing helpers and patterns instead of re-implementing similar logic
- Avoid redundant intermediate variables when the expression is clear (although consider gas cost implications, especially for mainnet contracts)
- Prefer early returns to reduce nesting

## Linting

Run `yarn lint-fix` to auto-fix all lint issues. For checking only: `yarn lint-solidity` (Solhint) and `yarn lint-js` (Prettier).

## License

BUSL-1.1 (see LICENSE file for exceptions)
