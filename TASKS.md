# Chain Adapter Tests Migration: Hardhat to Foundry

## Prompt for Task Picker

Pick the next highest priority item to implement and go implement it, implementing the common dependencies if any and putting them into some common folders to reuse for later tasks as well. Pick only a single task and complete it fully. Then stop. Run a targeted test command when done (e.g., `forge test --match-contract Ethereum_AdapterTest -vvv`). Also compare the tests implemented with the Hardhat version. The number and the semantics of each test should match.

---

## Workflow Instructions

### How to work with this file

1. Assess and pick the next task based on your priority criteria
2. Migrate the test following the patterns in existing Foundry tests
3. Create any common mocks/utilities in reusable locations
4. Run the new Foundry test to verify it works
5. Compare test count and semantics with original Hardhat test
6. Append progress notes to `chain-adapter-tests-migration.txt`
7. Mark task complete by adding `[x]` or remove the task from this file

### Progress tracking

Use `chain-adapter-tests-migration.txt` to log:

- Date of migration
- Any issues encountered
- New mocks or utilities created (and their locations)
- Deviations from original test behavior
- Notes for future migrations

### Reference files

- **Example migration**: Compare `test/evm/hardhat/chain-adapters/Arbitrum_Adapter.ts` with `test/evm/foundry/local/Arbitrum_Adapter.t.sol`
- **Test base**: `test/evm/foundry/utils/HubPoolTestBase.sol` - provides fixture, constants, utilities
- **Merkle utils**: `test/evm/foundry/utils/MerkleTreeUtils.sol` - merkle tree building
- **Existing mocks**: `contracts/test/` - MockCCTP.sol, MockOFTMessenger.sol, ArbitrumMocks.sol, PolygonMocks.sol, SuccinctMocks.sol, etc.

### Mock reuse guidelines

**IMPORTANT**: Always check `contracts/test/` for existing mock implementations before creating new ones.

1. **Use existing mocks** - Many mocks already exist and should be reused:

   - `MockSpokePool.sol` - Full SpokePool mock (use with ERC1967Proxy for UUPS pattern)
   - `MockCCTP.sol` - CCTP messenger and minter mocks
   - `MockOFTMessenger.sol` - OFT bridge mock
   - `ArbitrumMocks.sol` - Arbitrum bridge mocks (Inbox, GatewayRouter)
   - `PolygonMocks.sol` - Polygon bridge mocks
   - `SuccinctMocks.sol` - Succinct/Telepathy mocks

2. **Extend existing mocks** - If an existing mock is missing functionality:

   - Add the new function/event to the existing mock in `contracts/test/`
   - This keeps mocks centralized and reusable across tests

3. **Create new mocks only when necessary** - If no suitable mock exists:

   - Create in `contracts/test/` with naming pattern `<Chain>Mocks.sol`
   - Document the mock's purpose and usage

4. **Use constants for addresses** - Avoid inline `makeAddr()` calls:
   - Define address constants at the contract level
   - Example: `address constant CROSS_DOMAIN_ADMIN = address(0xAD1);`

---

## Tasks

### [x] Ethereum_Adapter

**Source**: `test/evm/hardhat/chain-adapters/Ethereum_Adapter.ts`
**Target**: `test/evm/foundry/local/Ethereum_Adapter.t.sol`

**Tests to migrate (2 tests)**:

- `relayMessage calls spoke pool functions`
- `Correctly transfers tokens when executing pool rebalance`

**Dependencies**:

- HubPoolTestBase (exists)
- MerkleTreeUtils (exists)
- No external bridge mocks needed (direct L1 adapter)

**Notes**: No fake external contracts needed. Tests direct L1 message relay and token transfer.

---

### [x] Arbitrum_SendTokensAdapter

**Source**: `test/evm/hardhat/chain-adapters/Arbitrum_SendTokensAdapter.ts`
**Target**: `test/evm/foundry/local/Arbitrum_SendTokensAdapter.t.sol`

**Tests to migrate (1 test)**:

- `relayMessage sends desired ERC20 in specified amount to SpokePool`

**Dependencies**:

- HubPoolTestBase (exists)
- ArbitrumMocks.sol (exists - ArbitrumMockErc20GatewayRouter)

**Notes**: Emergency/simplified token adapter. Uses same mocks as main Arbitrum adapter.

---

### [ ] Solana_Adapter

**Source**: `test/evm/hardhat/chain-adapters/Solana_Adapter.ts`
**Target**: `test/evm/foundry/local/Solana_Adapter.t.sol`

**Tests to migrate (2 tests)**:

- `relayMessage calls spoke pool functions`
- `Correctly calls the CCTP bridge adapter when attempting to bridge USDC`

**Dependencies**:

- HubPoolTestBase (exists)
- MerkleTreeUtils (exists)
- MockCCTP.sol (exists - MockCCTPMessenger, MockCCTPMinter)
- May need: MockCCTPMessageTransmitter (check if exists or create)

**Special handling**:

- Solana addresses are bytes32, need to implement `trimSolanaAddress` utility
- CCTP message transmission to Solana domain (domain ID 5)

**Notes**: CCTP-only adapter with Solana address handling.

---

### [ ] Optimism_Adapter

**Source**: `test/evm/hardhat/chain-adapters/Optimism_Adapter.ts`
**Target**: `test/evm/foundry/local/Optimism_Adapter.t.sol`

**Tests to migrate (4 tests)**:

- `relayMessage calls spoke pool functions`
- `Correctly calls appropriate Optimism bridge functions when making ERC20 cross chain calls`
- `Correctly unwraps WETH and bridges ETH`
- `Correctly calls the CCTP bridge adapter when attempting to bridge USDC`

**Dependencies**:

- HubPoolTestBase (exists)
- MerkleTreeUtils (exists)
- MockCCTP.sol (exists)
- Need: Mock L1CrossDomainMessenger, Mock L1StandardBridge (may exist in MockBedrockStandardBridge.sol or need to create)

**Notes**: Tests standard Optimism bridge + CCTP.

---

### [ ] Scroll_Adapter

**Source**: `test/evm/hardhat/chain-adapters/Scroll_Adapter.ts`
**Target**: `test/evm/foundry/local/Scroll_Adapter.t.sol`

**Tests to migrate (3 tests)**:

- `relayMessage fails when there's not enough fees`
- `relayMessage calls spoke pool functions`
- `Correctly calls appropriate scroll bridge functions when transferring tokens to different chains`

**Dependencies**:

- HubPoolTestBase (exists)
- MerkleTreeUtils (exists)
- Need: ScrollMocks.sol with:
  - MockScrollL1Messenger
  - MockScrollL1GasPriceOracle
  - MockScrollL1GatewayRouter

**Special handling**:

- Gas price oracle mocking for fee calculation
- Parametrized gas limits

**Notes**: Custom ABIs defined inline in Hardhat test - need to create proper mock contracts.

---

### [ ] PolygonZkEVM_Adapter

**Source**: `test/evm/hardhat/chain-adapters/PolygonZkEVM_Adapter.ts`
**Target**: `test/evm/foundry/local/PolygonZkEVM_Adapter.t.sol`

**Tests to migrate (3 tests)**:

- `relayMessage calls spoke pool functions`
- `Correctly calls appropriate bridge functions when making WETH cross chain calls`
- `Correctly calls appropriate bridge functions when making ERC20 cross chain calls`

**Dependencies**:

- HubPoolTestBase (exists)
- MerkleTreeUtils (exists)
- Need: PolygonZkEVMMocks.sol with MockPolygonZkEVMBridge

**Special handling**:

- Hardhat test uses Smock library - convert to native Foundry vm.mockCall or create mock contract
- Bridge asset and message methods with permit data support

**Notes**: Uses Smock in Hardhat - convert to Foundry mocking patterns.

---

### [ ] Linea_Adapter

**Source**: `test/evm/hardhat/chain-adapters/Linea_Adapter.ts`
**Target**: `test/evm/foundry/local/Linea_Adapter.t.sol`

**Tests to migrate (5 tests)**:

- `relayMessage calls spoke pool functions`
- `Correctly calls appropriate bridge functions when making ERC20 cross chain calls`
- `Correctly calls the CCTP bridge adapter when attempting to bridge USDC`
- `Splits USDC into parts to stay under per-message limit when attempting to bridge USDC`
- `Correctly unwraps WETH and bridges ETH`

**Dependencies**:

- HubPoolTestBase (exists)
- MerkleTreeUtils (exists)
- MockCCTP.sol (exists, but need CCTP V2 variant)
- Need: LineaMocks.sol with:
  - MockLineaMessageService
  - MockLineaTokenBridge

**Special handling**:

- Uses Smock library - convert to Foundry
- CCTP V2 messenger (different interface from V1)
- Heavy ETH funding for message fees
- WETH unwrap test

**Notes**: CCTP V2 may require new mock or extending existing MockCCTP.

---

### [ ] Polygon_Adapter

**Source**: `test/evm/hardhat/chain-adapters/Polygon_Adapter.ts`
**Target**: `test/evm/foundry/local/Polygon_Adapter.t.sol`

**Tests to migrate (6 tests)**:

- `relayMessage calls spoke pool functions`
- `Correctly calls appropriate Polygon bridge functions when making ERC20 cross chain calls`
- `Correctly unwraps WETH and bridges ETH`
- `Correctly bridges matic`
- `Correctly calls the CCTP bridge adapter when attempting to bridge USDC`
- `Correctly calls the OFT bridge adapter when attempting to bridge USDT`

**Dependencies**:

- HubPoolTestBase (exists)
- MerkleTreeUtils (exists)
- MockCCTP.sol (exists)
- MockOFTMessenger.sol (exists)
- PolygonMocks.sol (exists - check what's included)
- AdapterStore.sol (exists)
- May need additional mocks:
  - MockRootChainManager
  - MockFxStateSender
  - MockDepositManager (for Plasma/MATIC)

**Special handling**:

- Multiple bridge mechanisms: PoS (most tokens), Plasma (MATIC), CCTP (USDC), OFT (USDT)
- WETH unwrapping to ETH
- MATIC special routing via deposit manager
- Uses ExpandedERC20 for MATIC token (Uma dependency)

**Notes**: Tests 4 different bridge mechanisms. Check PolygonMocks.sol for existing mocks before creating new ones.

---

## Summary

| Adapter                    | Test Count | New Mocks Needed         | Status |
| -------------------------- | ---------- | ------------------------ | ------ |
| Ethereum_Adapter           | 2          | None                     | [x]    |
| Arbitrum_SendTokensAdapter | 1          | None (exists)            | [x]    |
| Solana_Adapter             | 2          | Maybe transmitter mock   | [ ]    |
| Optimism_Adapter           | 4          | Messenger + Bridge mocks | [ ]    |
| Scroll_Adapter             | 3          | ScrollMocks.sol          | [ ]    |
| PolygonZkEVM_Adapter       | 3          | PolygonZkEVMMocks.sol    | [ ]    |
| Linea_Adapter              | 5          | LineaMocks.sol + CCTP V2 | [ ]    |
| Polygon_Adapter            | 6          | Check PolygonMocks.sol   | [ ]    |

---

## Already Migrated (Reference)

- [x] Arbitrum_Adapter.ts → Arbitrum_Adapter.t.sol
- [x] Arbitrum_SendTokensAdapter.ts → Arbitrum_SendTokensAdapter.t.sol
- [x] Ethereum_Adapter.ts → Ethereum_Adapter.t.sol
