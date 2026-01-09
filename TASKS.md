# Chain Adapter Tests Polish: Foundry Best Practices

## Prompt for Task Picker

Pick the next highest priority item from the tasks below and complete it fully. Then stop.

**For each task:**

1. Read the Foundry test file
2. Read the corresponding Hardhat test file (`test/evm/hardhat/chain-adapters/<Name>_Adapter.ts`)
3. Compare the tests:
   - Does the Foundry test have the same number of test cases?
   - Does each test verify the same conditions/assertions?
   - Is the Foundry test more lax (fewer checks) than the Hardhat test?
4. Apply the fix described in the task
5. Run the targeted test command (e.g., `forge test --match-contract Arbitrum_AdapterTest -vvv`)
6. Verify all tests pass

**Critical: Test semantics must match the original Hardhat tests.** If the Foundry test is missing checks that the Hardhat test has, add them. We cannot have weaker tests after migration.

---

## Workflow Instructions

### How to work with this file

1. Pick the next task based on priority
2. Read both Foundry and Hardhat tests to understand current state
3. Apply the fix following patterns in existing polished tests
4. Run the test to verify it passes
5. Mark task complete by adding `[x]`

### Reference patterns

**Preferred: `vm.mockCall` + `vm.expectCall`** (see `Scroll_Adapter.t.sol`, `PolygonZkEVM_Adapter.t.sol`):

```solidity
// Put dummy bytecode at fake address (avoids extcodesize check)
vm.etch(fakeAddress, hex"00");

// Mock return values
vm.mockCall(fakeAddress, abi.encodeWithSelector(SELECTOR), abi.encode(returnValue));

// Verify calls with correct params (call BEFORE the action)
vm.expectCall(fakeAddress, msgValue, abi.encodeWithSelector(SELECTOR, arg1, arg2));
```

**Alternative: Mock contracts with call tracking** (see `Optimism_Adapter.t.sol`, `Polygon_Adapter.t.sol`):

```solidity
// In mock contract:
uint256 public myFunctionCallCount;
struct MyFunctionCall { address arg1; uint256 arg2; }
MyFunctionCall public lastMyFunctionCall;

function myFunction(address arg1, uint256 arg2) external {
    myFunctionCallCount++;
    lastMyFunctionCall = MyFunctionCall(arg1, arg2);
    // ... actual mock logic
}

// In test:
assertEq(mock.myFunctionCallCount(), 1, "myFunction should be called once");
(address a1, uint256 a2) = mock.lastMyFunctionCall();
assertEq(a1, expectedArg1);
assertEq(a2, expectedArg2);
```

**Avoid: Events to signal mock calls** (anti-pattern):

```solidity
// DON'T DO THIS - events are indirect and harder to debug
event MyFunctionCalled(address arg1, uint256 arg2);

function myFunction(address arg1, uint256 arg2) external {
    emit MyFunctionCalled(arg1, arg2);
}

// In test:
vm.expectEmit(...);
emit MockContract.MyFunctionCalled(expectedArg1, expectedArg2);
```

### When to use each pattern

| Pattern                       | Use When                                                                        |
| ----------------------------- | ------------------------------------------------------------------------------- |
| `vm.mockCall`/`vm.expectCall` | Simple return value mocking, no side effects needed                             |
| Mock with call tracking       | Need side effects (token transfers), complex state, or multiple calls to verify |
| Events                        | Only for testing actual contract events, NOT for mock verification              |

---

## Tasks

### [ ] Arbitrum_Adapter: Replace event-based verification with call tracking

**Source**: `test/evm/foundry/local/Arbitrum_Adapter.t.sol`
**Hardhat reference**: `test/evm/hardhat/chain-adapters/Arbitrum_Adapter.ts`

**Current pattern (anti-pattern)**:

- Uses `vm.expectEmit` with `Inbox.RetryableTicketCreated`
- Uses `vm.expectEmit` with `ArbitrumMockErc20GatewayRouter.OutboundTransferCustomRefundCalled`
- Uses `vm.expectEmit` with `MockCCTPMessenger.DepositForBurnCalled`

**Target pattern**:

- Add call tracking to `Inbox` mock (`createRetryableTicketCallCount`, `lastCreateRetryableTicketCall`)
- Add call tracking to `ArbitrumMockErc20GatewayRouter` (`outboundTransferCustomRefundCallCount`, `lastOutboundTransferCustomRefundCall`)
- Use existing `MockCCTPMessenger.lastDepositForBurnCall()` (already has call tracking)
- Replace `vm.expectEmit` with assertions on call counts and parameters

**Also verify**: Test coverage matches Hardhat test (same number of tests, same assertions).

**Mocks to update**: `contracts/test/ArbitrumMocks.sol`

---

### [ ] Arbitrum_SendTokensAdapter: Replace event-based verification with call tracking

**Source**: `test/evm/foundry/local/Arbitrum_SendTokensAdapter.t.sol`
**Hardhat reference**: `test/evm/hardhat/chain-adapters/Arbitrum_SendTokensAdapter.ts`

**Current pattern (anti-pattern)**:

- Uses `vm.expectEmit` with `ArbitrumMockErc20GatewayRouter.OutboundTransferCustomRefundCalled`

**Target pattern**:

- Reuse the call tracking added to `ArbitrumMockErc20GatewayRouter` from the Arbitrum_Adapter task
- Replace `vm.expectEmit` with assertions on call counts and parameters

**Also verify**: Test coverage matches Hardhat test.

---

### [ ] Ethereum_Adapter: Verify test coverage matches Hardhat

**Source**: `test/evm/foundry/local/Ethereum_Adapter.t.sol`
**Hardhat reference**: `test/evm/hardhat/chain-adapters/Ethereum_Adapter.ts`

**Current state**:

- Uses `vm.expectEmit` with `AdapterInterface.MessageRelayed` and `AdapterInterface.TokensRelayed`
- These are actual adapter interface events, so the pattern is acceptable

**Task**:

- Compare test coverage with Hardhat test
- Ensure all assertions from Hardhat test are present in Foundry test
- No pattern change needed unless coverage is lacking

---

### [ ] Scroll_Adapter: Verify test coverage matches Hardhat

**Source**: `test/evm/foundry/local/Scroll_Adapter.t.sol`
**Hardhat reference**: `test/evm/hardhat/chain-adapters/Scroll_Adapter.ts`

**Current state**: Uses `vm.mockCall`/`vm.expectCall` pattern (correct)

**Task**:

- Compare test coverage with Hardhat test
- Ensure all assertions are equivalent
- Verify the `test_relayMessage_RevertsWhenInsufficientFees` test has equivalent behavior

---

### [ ] PolygonZkEVM_Adapter: Verify test coverage matches Hardhat

**Source**: `test/evm/foundry/local/PolygonZkEVM_Adapter.t.sol`
**Hardhat reference**: `test/evm/hardhat/chain-adapters/PolygonZkEVM_Adapter.ts`

**Current state**: Uses `vm.mockCall`/`vm.expectCall` pattern (correct)

**Task**:

- Compare test coverage with Hardhat test
- Ensure all assertions are equivalent

---

### [ ] Linea_Adapter: Verify test coverage matches Hardhat

**Source**: `test/evm/foundry/local/Linea_Adapter.t.sol`
**Hardhat reference**: `test/evm/hardhat/chain-adapters/Linea_Adapter.ts`

**Current state**: Mix of `vm.expectCall` and `MockCCTPMessengerV2` with call tracking (correct)

**Task**:

- Compare test coverage with Hardhat test
- Ensure all 5 tests have equivalent assertions

---

### [ ] Optimism_Adapter: Verify test coverage matches Hardhat

**Source**: `test/evm/foundry/local/Optimism_Adapter.t.sol`
**Hardhat reference**: `test/evm/hardhat/chain-adapters/Optimism_Adapter.ts`

**Current state**: Uses call tracking pattern (correct)

**Task**:

- Compare test coverage with Hardhat test
- Ensure all 4 tests have equivalent assertions

---

### [ ] Polygon_Adapter: Verify test coverage matches Hardhat

**Source**: `test/evm/foundry/local/Polygon_Adapter.t.sol`
**Hardhat reference**: `test/evm/hardhat/chain-adapters/Polygon_Adapter.ts`

**Current state**: Uses call tracking pattern (correct)

**Task**:

- Compare test coverage with Hardhat test
- Ensure all 6 tests have equivalent assertions

---

### [ ] Solana_Adapter: Verify test coverage matches Hardhat

**Source**: `test/evm/foundry/local/Solana_Adapter.t.sol`
**Hardhat reference**: `test/evm/hardhat/chain-adapters/Solana_Adapter.ts`

**Current state**: Uses call tracking pattern (correct)

**Task**:

- Compare test coverage with Hardhat test
- Ensure all 2 tests have equivalent assertions

---

## Summary

| Adapter                    | Issue                         | Priority |
| -------------------------- | ----------------------------- | -------- |
| Arbitrum_Adapter           | Event-based mock verification | High     |
| Arbitrum_SendTokensAdapter | Event-based mock verification | High     |
| Ethereum_Adapter           | Verify coverage               | Medium   |
| Scroll_Adapter             | Verify coverage               | Medium   |
| PolygonZkEVM_Adapter       | Verify coverage               | Medium   |
| Linea_Adapter              | Verify coverage               | Medium   |
| Optimism_Adapter           | Verify coverage               | Medium   |
| Polygon_Adapter            | Verify coverage               | Medium   |
| Solana_Adapter             | Verify coverage               | Medium   |

---

## Best Practices Reference (from CLAUDE.md)

### Mock patterns

1. **Check existing mocks first**: `contracts/test/` has `MockCCTP.sol`, `ArbitrumMocks.sol`, `PolygonMocks.sol`, etc.

2. **MockSpokePool requires UUPS proxy**:

   ```solidity
   new ERC1967Proxy(
       address(new MockSpokePool(weth)),
       abi.encodeCall(MockSpokePool.initialize, (...))
   )
   ```

3. **`vm.mockCall` pattern** (preferred for simple cases):

   ```solidity
   vm.etch(fakeAddr, hex"00");  // Bypass extcodesize check
   vm.mockCall(fakeAddr, abi.encodeWithSelector(SELECTOR), abi.encode(returnVal));
   vm.expectCall(fakeAddr, msgValue, abi.encodeWithSelector(SELECTOR, arg1));
   ```

4. **Delegatecall context**: Adapter tests via HubPool emit events from HubPool's address; `vm.expectRevert()` may lose error data

### Test gotchas

- Events emitted in delegatecall appear from HubPool's address, not adapter's
- Use `vm.expectRevert()` without message when error data might be stripped
- Call `vm.expectCall` BEFORE the action that triggers the call
