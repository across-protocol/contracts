# Universal SpokePool Bridge Adapter Architecture

## Problem Statement

The existing Universal SpokePool provides flexibility for USDC (via CCTP) and OFT routing, but lacks support for other bridge types such as:

- OP native ERC20 bridge (Optimism Standard Bridge)
- Arbitrum ERC20 gateway
- Custom chain-specific bridges

This limitation was identified during MegaETH deployment, where support for the OP native (Ether) bridge was required, forcing an OP_SpokePool deployment instead of a Universal SpokePool deployment.

As new chains (especially alt L1s) launch with increasingly bespoke token configurations, a more flexible bridging architecture is needed.

## Current Architecture

### Bridge Flow in Universal_SpokePool

```solidity
function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
  address oftMessenger = _getOftMessenger(l2TokenAddress);

  if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
    _transferUsdc(withdrawalRecipient, amountToReturn);
  } else if (oftMessenger != address(0)) {
    _fundedTransferViaOft(IERC20(l2TokenAddress), IOFT(oftMessenger), withdrawalRecipient, amountToReturn);
  } else {
    revert NotImplemented();
  }
}
```

### Limitations

1. **Hard-coded bridge types**: Only CCTP and OFT are supported
2. **No extensibility**: Adding new bridge types requires contract modification
3. **Deployment fragmentation**: Different chains need different SpokePool implementations
4. **Maintenance burden**: Each chain-specific SpokePool duplicates core logic

---

## Design Options

### Option A: Bridge Adapter Registry

**Concept**: Add a configurable registry that maps tokens to bridge adapter contracts. Each adapter implements a standard interface.

```solidity
interface IBridgeAdapter {
  /// @notice Bridge tokens to L1
  /// @param l2Token The L2 token address
  /// @param l1Token The corresponding L1 token address
  /// @param to Recipient on L1
  /// @param amount Amount to bridge
  /// @param bridgeData Additional bridge-specific data
  function bridge(
    address l2Token,
    address l1Token,
    address to,
    uint256 amount,
    bytes calldata bridgeData
  ) external payable;

  /// @notice Quote native fee required for bridging
  function quoteBridgeFee(address l2Token, uint256 amount, bytes calldata bridgeData) external view returns (uint256);
}
```

**Storage Structure**:

```solidity
// Token -> Adapter mapping
mapping(address l2Token => address adapter) public bridgeAdapters;

// Default adapter for tokens without specific mapping
address public defaultBridgeAdapter;

// L2 -> L1 token mapping (reused from existing pattern)
mapping(address l2Token => address l1Token) public remoteL1Tokens;
```

**Modified \_bridgeTokensToHubPool**:

```solidity
function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
  address adapter = bridgeAdapters[l2TokenAddress];
  if (adapter == address(0)) {
    adapter = defaultBridgeAdapter;
  }
  require(adapter != address(0), "No bridge adapter configured");

  address l1Token = remoteL1Tokens[l2TokenAddress];
  IERC20(l2TokenAddress).safeIncreaseAllowance(adapter, amountToReturn);

  IBridgeAdapter(adapter).bridge(
    l2TokenAddress,
    l1Token,
    withdrawalRecipient,
    amountToReturn,
    "" // bridgeData from storage or empty
  );
}
```

**Example Adapters**:

```solidity
contract OPStandardBridgeAdapter is IBridgeAdapter {
  IL2ERC20Bridge public immutable l2Bridge;
  uint32 public immutable l1Gas;

  function bridge(address l2Token, address l1Token, address to, uint256 amount, bytes calldata) external payable {
    IERC20(l2Token).safeTransferFrom(msg.sender, address(this), amount);
    IERC20(l2Token).safeIncreaseAllowance(address(l2Bridge), amount);

    if (l1Token != address(0)) {
      l2Bridge.bridgeERC20To(l2Token, l1Token, to, amount, l1Gas, "");
    } else {
      l2Bridge.withdrawTo(l2Token, to, amount, l1Gas, "");
    }
  }
}

contract CCTPBridgeAdapter is IBridgeAdapter {
  // Wraps existing CircleCCTPAdapter logic
}

contract OFTBridgeAdapter is IBridgeAdapter {
  // Wraps existing OFTTransportAdapter logic
}
```

#### Pros

- Clean separation of concerns
- Easy to add new bridge types without modifying SpokePool
- Each adapter can be audited independently
- Adapters are reusable across multiple SpokePools
- Simple mental model: token → adapter → bridge

#### Cons

- Additional external calls (gas overhead)
- More contracts to deploy and manage
- Adapter upgrade requires re-configuration
- Token approvals to external contracts increase attack surface
- Fee handling complexity (native fees vary by bridge)

---

### Option B: Bridge Router Pattern

**Concept**: Single router contract handles all bridge routing decisions internally. SpokePool only interacts with one contract.

```solidity
interface IBridgeRouter {
  function bridgeToL1(address l2Token, address recipient, uint256 amount) external payable;

  function quoteBridgeFee(address l2Token, uint256 amount) external view returns (uint256);
}
```

**Router Implementation**:

```solidity
contract UniversalBridgeRouter is IBridgeRouter, Ownable {
  enum BridgeType {
    NONE,
    CCTP,
    OFT,
    OP_STANDARD,
    ARBITRUM_GATEWAY,
    CUSTOM
  }

  struct BridgeConfig {
    BridgeType bridgeType;
    address bridgeContract; // Bridge-specific contract
    address l1Token; // Corresponding L1 token
    bytes extraData; // Bridge-specific config
  }

  mapping(address l2Token => BridgeConfig) public bridgeConfigs;

  function bridgeToL1(address l2Token, address recipient, uint256 amount) external payable {
    BridgeConfig memory config = bridgeConfigs[l2Token];

    IERC20(l2Token).safeTransferFrom(msg.sender, address(this), amount);

    if (config.bridgeType == BridgeType.CCTP) {
      _bridgeViaCCTP(l2Token, recipient, amount, config);
    } else if (config.bridgeType == BridgeType.OFT) {
      _bridgeViaOFT(l2Token, recipient, amount, config);
    } else if (config.bridgeType == BridgeType.OP_STANDARD) {
      _bridgeViaOPStandard(l2Token, recipient, amount, config);
    } else if (config.bridgeType == BridgeType.ARBITRUM_GATEWAY) {
      _bridgeViaArbitrumGateway(l2Token, recipient, amount, config);
    } else {
      revert("Unsupported bridge type");
    }
  }

  // Internal bridge implementations...
}
```

**Modified SpokePool**:

```solidity
contract Universal_SpokePool is SpokePool {
  IBridgeRouter public bridgeRouter;

  function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
    IERC20(l2TokenAddress).safeIncreaseAllowance(address(bridgeRouter), amountToReturn);
    uint256 fee = bridgeRouter.quoteBridgeFee(l2TokenAddress, amountToReturn);
    bridgeRouter.bridgeToL1{ value: fee }(l2TokenAddress, withdrawalRecipient, amountToReturn);
  }
}
```

#### Pros

- Single point of configuration
- SpokePool stays simple
- Router can be upgraded independently
- Centralized fee management
- Can optimize gas by batching bridge calls

#### Cons

- Router becomes a complex, high-risk contract
- All bridge logic in one place = larger audit surface
- Adding new bridge types requires router upgrade
- Single point of failure
- May accumulate technical debt as bridges are added

---

### Option C: Composable Adapter Inheritance

**Concept**: Keep current inheritance pattern but make adapters composable via multiple inheritance or mixins.

```solidity
// Base adapter interface
abstract contract BridgeAdapterBase {
  function _canBridge(address token) internal view virtual returns (bool);
  function _doBridge(address token, address to, uint256 amount) internal virtual;
}

// Composable adapters
abstract contract CCTPBridgeMixin is BridgeAdapterBase {
  function _canBridge(address token) internal view virtual override returns (bool) {
    return _isCCTPEnabled() && token == address(usdcToken);
  }
  function _doBridge(address token, address to, uint256 amount) internal virtual override {
    _transferUsdc(to, amount);
  }
}

abstract contract OFTBridgeMixin is BridgeAdapterBase {
  function _canBridge(address token) internal view virtual override returns (bool) {
    return _getOftMessenger(token) != address(0);
  }
  function _doBridge(address token, address to, uint256 amount) internal virtual override {
    _fundedTransferViaOft(IERC20(token), IOFT(_getOftMessenger(token)), to, amount);
  }
}

abstract contract OPStandardBridgeMixin is BridgeAdapterBase {
  mapping(address => bool) public useOPBridge;
  // ...
}
```

**Composable SpokePool**:

```solidity
contract MegaETH_SpokePool is Universal_SpokePool, OPStandardBridgeMixin {
  function _bridgeTokensToHubPool(uint256 amount, address token) internal override {
    if (CCTPBridgeMixin._canBridge(token)) {
      CCTPBridgeMixin._doBridge(token, withdrawalRecipient, amount);
    } else if (OFTBridgeMixin._canBridge(token)) {
      OFTBridgeMixin._doBridge(token, withdrawalRecipient, amount);
    } else if (OPStandardBridgeMixin._canBridge(token)) {
      OPStandardBridgeMixin._doBridge(token, withdrawalRecipient, amount);
    } else {
      revert NotImplemented();
    }
  }
}
```

#### Pros

- Familiar pattern (similar to current architecture)
- Compile-time composition = gas efficient
- No external calls to adapter contracts
- Type-safe, easier to reason about

#### Cons

- Requires new contract deployment for each configuration
- Diamond inheritance complexity
- Cannot add new bridge types without redeployment
- Code duplication if many variants needed
- Testing combinatorial explosion

---

### Option D: Delegatecall Plugin System

**Concept**: Upgradeable plugin slots that execute bridging logic via delegatecall, keeping state in SpokePool.

```solidity
contract Universal_SpokePool is SpokePool {
  // Plugin registry
  mapping(bytes4 bridgeTypeId => address implementation) public bridgePlugins;

  // Per-token bridge type assignment
  mapping(address l2Token => bytes4 bridgeTypeId) public tokenBridgeTypes;

  function _bridgeTokensToHubPool(uint256 amount, address l2Token) internal override {
    bytes4 bridgeType = tokenBridgeTypes[l2Token];
    address plugin = bridgePlugins[bridgeType];
    require(plugin != address(0), "No plugin for bridge type");

    // Delegatecall preserves SpokePool's storage context
    (bool success, ) = plugin.delegatecall(
      abi.encodeWithSignature("bridge(address,address,uint256)", l2Token, withdrawalRecipient, amount)
    );
    require(success, "Bridge plugin failed");
  }

  function setBridgePlugin(bytes4 bridgeTypeId, address implementation) external onlyOwner {
    bridgePlugins[bridgeTypeId] = implementation;
  }

  function setTokenBridgeType(address l2Token, bytes4 bridgeTypeId) external onlyOwner {
    tokenBridgeTypes[l2Token] = bridgeTypeId;
  }
}
```

**Plugin Implementation**:

```solidity
contract OPStandardBridgePlugin {
  // This contract is stateless - it operates on caller's storage via delegatecall

  // Storage slots must match SpokePool layout or use explicit slots
  bytes32 constant WITHDRAWAL_RECIPIENT_SLOT = keccak256("withdrawalRecipient");

  function bridge(address l2Token, address to, uint256 amount) external {
    // Access SpokePool storage
    address l1Token = _getRemoteL1Token(l2Token);

    IERC20(l2Token).safeIncreaseAllowance(L2_STANDARD_BRIDGE, amount);
    IL2ERC20Bridge(L2_STANDARD_BRIDGE).bridgeERC20To(l2Token, l1Token, to, amount, 200000, "");
  }
}
```

#### Pros

- Maximum flexibility without redeployment
- Plugins share SpokePool's storage context
- Can upgrade individual bridge implementations
- Clean separation while maintaining single contract UX

#### Cons

- Delegatecall is dangerous (storage layout must match exactly)
- Complex to audit and verify correctness
- Plugin bugs can corrupt SpokePool storage
- Harder to reason about state changes
- Gas overhead from delegatecall

---

### Option E: Hybrid Approach (Recommended)

**Concept**: Built-in support for common patterns (CCTP, OFT) with a configurable adapter fallback for custom bridges.

```solidity
contract Universal_SpokePool is SpokePool, CircleCCTPAdapter, OFTTransportAdapter {
  // Fallback adapter for tokens not handled by built-in bridges
  mapping(address l2Token => address adapter) public customBridgeAdapters;
  mapping(address l2Token => address l1Token) public remoteL1Tokens;
  mapping(address l2Token => bytes) public bridgeExtraData;

  function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
    // Priority 1: CCTP for USDC
    if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
      _transferUsdc(withdrawalRecipient, amountToReturn);
      return;
    }

    // Priority 2: OFT if configured
    address oftMessenger = _getOftMessenger(l2TokenAddress);
    if (oftMessenger != address(0)) {
      _fundedTransferViaOft(IERC20(l2TokenAddress), IOFT(oftMessenger), withdrawalRecipient, amountToReturn);
      return;
    }

    // Priority 3: Custom adapter if configured
    address adapter = customBridgeAdapters[l2TokenAddress];
    if (adapter != address(0)) {
      _bridgeViaAdapter(l2TokenAddress, amountToReturn, adapter);
      return;
    }

    revert NotImplemented();
  }

  function _bridgeViaAdapter(address l2Token, uint256 amount, address adapter) internal {
    address l1Token = remoteL1Tokens[l2Token];
    bytes memory extraData = bridgeExtraData[l2Token];

    IERC20(l2Token).safeIncreaseAllowance(adapter, amount);

    uint256 fee = IBridgeAdapter(adapter).quoteBridgeFee(l2Token, amount, extraData);
    IBridgeAdapter(adapter).bridge{ value: fee }(l2Token, l1Token, withdrawalRecipient, amount, extraData);
  }

  // Admin functions (called via HubPool relay)
  function setCustomBridgeAdapter(address l2Token, address adapter) external onlyAdmin {
    customBridgeAdapters[l2Token] = adapter;
    emit CustomBridgeAdapterSet(l2Token, adapter);
  }

  function setRemoteL1Token(address l2Token, address l1Token) external onlyAdmin {
    remoteL1Tokens[l2Token] = l1Token;
    emit RemoteL1TokenSet(l2Token, l1Token);
  }

  function setBridgeExtraData(address l2Token, bytes calldata data) external onlyAdmin {
    bridgeExtraData[l2Token] = data;
    emit BridgeExtraDataSet(l2Token, data);
  }
}
```

**Standard Adapter Library**:

```solidity
// Pre-built adapters that can be deployed once and reused

contract OPStandardBridgeAdapter is IBridgeAdapter {
  IL2ERC20Bridge public immutable l2Bridge;
  uint32 public l1Gas = 200_000;

  constructor(address _l2Bridge) {
    l2Bridge = IL2ERC20Bridge(_l2Bridge);
  }

  function bridge(
    address l2Token,
    address l1Token,
    address to,
    uint256 amount,
    bytes calldata
  ) external payable override {
    IERC20(l2Token).safeTransferFrom(msg.sender, address(this), amount);
    IERC20(l2Token).safeIncreaseAllowance(address(l2Bridge), amount);

    if (l1Token != address(0)) {
      l2Bridge.bridgeERC20To(l2Token, l1Token, to, amount, l1Gas, "");
    } else {
      l2Bridge.withdrawTo(l2Token, to, amount, l1Gas, "");
    }
  }

  function quoteBridgeFee(address, uint256, bytes calldata) external pure returns (uint256) {
    return 0; // OP bridge doesn't require native fee
  }
}

contract ArbitrumGatewayAdapter is IBridgeAdapter {
  address public immutable l2GatewayRouter;

  function bridge(
    address l2Token,
    address l1Token,
    address to,
    uint256 amount,
    bytes calldata
  ) external payable override {
    IERC20(l2Token).safeTransferFrom(msg.sender, address(this), amount);
    IERC20(l2Token).safeIncreaseAllowance(l2GatewayRouter, amount);

    ArbitrumL2ERC20GatewayLike(l2GatewayRouter).outboundTransfer(l1Token, to, amount, "");
  }

  function quoteBridgeFee(address, uint256, bytes calldata) external pure returns (uint256) {
    return 0;
  }
}

contract WETHUnwrapAdapter is IBridgeAdapter {
  // For chains where ETH must be unwrapped before bridging
  WETH9Interface public immutable weth;
  IBridgeAdapter public immutable underlyingAdapter;

  function bridge(
    address l2Token,
    address l1Token,
    address to,
    uint256 amount,
    bytes calldata extraData
  ) external payable override {
    require(l2Token == address(weth), "Not WETH");

    IERC20(l2Token).safeTransferFrom(msg.sender, address(this), amount);
    weth.withdraw(amount);

    // Forward to underlying adapter (e.g., OP ETH bridge)
    underlyingAdapter.bridge{ value: amount }(address(0), l1Token, to, amount, extraData);
  }
}
```

#### Pros

- Maintains gas efficiency for common paths (CCTP, OFT)
- Flexible fallback for custom bridges
- No contract upgrade needed to add new token support
- Adapters are isolated and independently auditable
- Familiar pattern building on existing code
- Graceful degradation (built-in → adapter → revert)

#### Cons

- Still requires adapter deployment for new bridge types
- Slightly more complex than pure adapter registry
- Multiple code paths to maintain
- Custom adapters still have external call overhead

---

## Recommendation

**Option E (Hybrid Approach)** is recommended for the following reasons:

1. **Backward Compatibility**: Maintains existing CCTP and OFT paths with no changes
2. **Incremental Adoption**: New bridges can be added without modifying core contract
3. **Gas Efficiency**: Common paths (USDC, OFT tokens) remain optimized
4. **Security**: Adapters are isolated; bugs don't affect built-in bridges
5. **Operational Flexibility**: Token-to-adapter mapping can be updated via HubPool governance
6. **Reusability**: Standard adapters (OP, Arbitrum) deployed once, used by many SpokePools

### Implementation Phases

**Phase 1: Interface & Core Changes**

- Define `IBridgeAdapter` interface
- Add adapter registry to `Universal_SpokePool`
- Add admin functions for configuration

**Phase 2: Standard Adapters**

- Implement `OPStandardBridgeAdapter`
- Implement `ArbitrumGatewayAdapter`
- Implement `WETHUnwrapAdapter` (composable)

**Phase 3: Migration & Testing**

- Deploy adapters to testnets
- Validate MegaETH scenario (OP bridge for ETH)
- Audit adapter contracts

**Phase 4: Production Rollout**

- Deploy adapters to mainnet
- Configure existing Universal SpokePools
- Document adapter development guidelines

---

## Comparison Matrix

| Criteria              | Option A | Option B | Option C | Option D | Option E                        |
| --------------------- | -------- | -------- | -------- | -------- | ------------------------------- |
| Flexibility           | High     | Medium   | Low      | High     | High                            |
| Gas Efficiency        | Medium   | Medium   | High     | Medium   | High (common) / Medium (custom) |
| Audit Complexity      | Medium   | High     | Low      | High     | Medium                          |
| Upgrade Path          | Easy     | Hard     | Redeploy | Easy     | Easy                            |
| Implementation Effort | Medium   | High     | Low      | High     | Medium                          |
| Risk Profile          | Medium   | High     | Low      | High     | Low-Medium                      |
| Backward Compatible   | Yes      | No       | No       | Yes      | Yes                             |

---

## Open Questions

1. **Fee Handling**: How should native bridge fees be funded? Options:

   - SpokePool holds ETH buffer
   - Fee pulled from relayer refund
   - Separate fee funding mechanism

2. **Adapter Governance**: Should adapter changes require:

   - HubPool governance vote?
   - Timelock delay?
   - Multi-sig approval?

3. **Adapter Verification**: How to ensure adapter correctness?

   - Whitelist of approved adapters?
   - On-chain verification of adapter behavior?
   - Integration test requirements?

4. **Cross-chain Adapter Consistency**: Should the same adapter be used across all SpokePools for a given bridge type, or can they differ per deployment?
