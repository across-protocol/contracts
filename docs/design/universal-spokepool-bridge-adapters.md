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

### Option D: Delegatecall Plugin System with ERC-7201 Namespaced Storage

**Concept**: Upgradeable plugin slots that execute bridging logic via delegatecall. Plugins use [ERC-7201](https://eips.ethereum.org/EIPS/eip-7201) namespaced storage to safely store their configuration state within the SpokePool contract, avoiding storage collisions.

#### Why ERC-7201?

Traditional delegatecall patterns are dangerous because plugins might accidentally read/write to storage slots used by the main contract. ERC-7201 solves this by defining a standard formula for computing storage namespaces:

```solidity
keccak256(abi.encode(uint256(keccak256("across.bridge-adapter.op-standard")) - 1)) & ~bytes32(uint256(0xff))
```

Each plugin declares its own namespace, and all its storage variables are stored at offsets from that base slot. This means:

- Plugins cannot accidentally collide with SpokePool storage
- Plugins cannot accidentally collide with each other
- Storage layout is deterministic and auditable

#### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         SpokePool                                │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Core Storage (slots 0-N)                                 │    │
│  │ - numberOfDeposits, fillStatuses, etc.                   │    │
│  └─────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ Plugin Registry (slots N+1...)                           │    │
│  │ - bridgePlugins mapping                                  │    │
│  │ - tokenBridgeTypes mapping                               │    │
│  └─────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ ERC-7201 Namespace: "across.bridge-adapter.op-standard"  │    │
│  │ - l2Bridge address                                       │    │
│  │ - l1Gas setting                                          │    │
│  │ - remoteL1Tokens mapping                                 │    │
│  └─────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ ERC-7201 Namespace: "across.bridge-adapter.cctp"         │    │
│  │ - cctpTokenMessenger                                     │    │
│  │ - recipientCircleDomainId                                │    │
│  └─────────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ ERC-7201 Namespace: "across.bridge-adapter.oft"          │    │
│  │ - oftMessengers mapping                                  │    │
│  │ - OFT_DST_EID                                            │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

#### Implementation

**SpokePool Core**:

```solidity
contract Universal_SpokePool is SpokePool {
  // Plugin registry (stored in SpokePool's normal storage)
  mapping(bytes4 bridgeTypeId => address implementation) public bridgePlugins;
  mapping(address l2Token => bytes4 bridgeTypeId) public tokenBridgeTypes;

  function _bridgeTokensToHubPool(uint256 amount, address l2Token) internal override {
    bytes4 bridgeType = tokenBridgeTypes[l2Token];
    address plugin = bridgePlugins[bridgeType];
    require(plugin != address(0), "No plugin for bridge type");

    // Delegatecall executes plugin code with SpokePool's storage context
    // Plugin reads its config from its ERC-7201 namespace
    (bool success, ) = plugin.delegatecall(
      abi.encodeWithSignature("bridge(address,address,uint256)", l2Token, withdrawalRecipient, amount)
    );
    require(success, "Bridge plugin failed");
  }

  // Admin functions to configure plugins (called via HubPool relay)
  function setBridgePlugin(bytes4 bridgeTypeId, address implementation) external onlyAdmin {
    bridgePlugins[bridgeTypeId] = implementation;
    emit BridgePluginSet(bridgeTypeId, implementation);
  }

  function setTokenBridgeType(address l2Token, bytes4 bridgeTypeId) external onlyAdmin {
    tokenBridgeTypes[l2Token] = bridgeTypeId;
    emit TokenBridgeTypeSet(l2Token, bridgeTypeId);
  }

  // Generic function to configure plugin storage via delegatecall
  function configurePlugin(bytes4 bridgeTypeId, bytes calldata configData) external onlyAdmin {
    address plugin = bridgePlugins[bridgeTypeId];
    require(plugin != address(0), "Plugin not registered");

    (bool success, ) = plugin.delegatecall(abi.encodeWithSignature("configure(bytes)", configData));
    require(success, "Plugin configuration failed");
  }
}
```

**Plugin Implementation with ERC-7201**:

```solidity
contract OPStandardBridgePlugin {
  // ERC-7201 storage namespace
  // keccak256(abi.encode(uint256(keccak256("across.bridge-adapter.op-standard")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant STORAGE_SLOT = 0x1a2b3c4d...; // Computed constant

  /// @custom:storage-location erc7201:across.bridge-adapter.op-standard
  struct OPBridgeStorage {
    address l2Bridge;
    uint32 l1Gas;
    mapping(address l2Token => address l1Token) remoteL1Tokens;
  }

  function _getStorage() private pure returns (OPBridgeStorage storage $) {
    assembly {
      $.slot := STORAGE_SLOT
    }
  }

  function bridge(address l2Token, address to, uint256 amount) external {
    OPBridgeStorage storage $ = _getStorage();

    address l1Token = $.remoteL1Tokens[l2Token];
    address l2Bridge = $.l2Bridge;
    uint32 l1Gas = $.l1Gas;

    IERC20(l2Token).safeIncreaseAllowance(l2Bridge, amount);

    if (l1Token != address(0)) {
      IL2ERC20Bridge(l2Bridge).bridgeERC20To(l2Token, l1Token, to, amount, l1Gas, "");
    } else {
      IL2ERC20Bridge(l2Bridge).withdrawTo(l2Token, to, amount, l1Gas, "");
    }
  }

  function configure(bytes calldata configData) external {
    OPBridgeStorage storage $ = _getStorage();

    // Decode and apply configuration
    (address l2Bridge, uint32 l1Gas) = abi.decode(configData, (address, uint32));
    $.l2Bridge = l2Bridge;
    $.l1Gas = l1Gas;
  }

  function setRemoteL1Token(address l2Token, address l1Token) external {
    OPBridgeStorage storage $ = _getStorage();
    $.remoteL1Tokens[l2Token] = l1Token;
  }
}

contract CCTPBridgePlugin {
  bytes32 private constant STORAGE_SLOT = 0x...; // Different namespace

  /// @custom:storage-location erc7201:across.bridge-adapter.cctp
  struct CCTPStorage {
    address cctpTokenMessenger;
    address cctpMinter;
    address usdcToken;
    uint32 recipientCircleDomainId;
  }

  function _getStorage() private pure returns (CCTPStorage storage $) {
    assembly {
      $.slot := STORAGE_SLOT
    }
  }

  function bridge(address l2Token, address to, uint256 amount) external {
    CCTPStorage storage $ = _getStorage();
    require(l2Token == $.usdcToken, "Not USDC");

    // Existing CCTP logic using namespaced storage...
    ITokenMessenger($.cctpTokenMessenger).depositForBurn(
      amount,
      $.recipientCircleDomainId,
      bytes32(uint256(uint160(to))),
      $.usdcToken
    );
  }

  function configure(bytes calldata configData) external {
    CCTPStorage storage $ = _getStorage();
    (
      address tokenMessenger,
      address minter,
      address usdc,
      uint32 domainId
    ) = abi.decode(configData, (address, address, address, uint32));

    $.cctpTokenMessenger = tokenMessenger;
    $.cctpMinter = minter;
    $.usdcToken = usdc;
    $.recipientCircleDomainId = domainId;
  }
}
```

#### Ownership & Admin Flow

All plugin configuration flows through the SpokePool's admin functions, which are controlled by HubPool governance:

```
HubPool.executeRootBundle()
  → relayMessage(spokePool, configurePlugin(bridgeTypeId, configData))
    → SpokePool.configurePlugin()
      → delegatecall to plugin.configure()
        → Plugin writes to its ERC-7201 namespace in SpokePool storage
```

This means:

- **Single admin**: HubPool owner controls all configuration
- **State lives in SpokePool**: No external adapter contracts with separate ownership
- **Auditable**: Plugin storage is isolated and deterministic

#### Pros

- Maximum flexibility without SpokePool redeployment
- Plugins can have complex state (mappings, arrays) safely via ERC-7201
- No storage collision risk between plugins or with SpokePool
- Gas efficient: no token transfers to external contracts
- Unified admin model: all config via HubPool governance
- **Symmetric with Hub → Spoke direction** (see Bidirectional Considerations below)

#### Cons

- More complex than external adapters (requires understanding ERC-7201)
- Plugins must be carefully audited (execute in SpokePool context)
- Plugin bugs could still cause issues (though not storage corruption)
- Requires tooling support for ERC-7201 storage verification
- Slight gas overhead from delegatecall (~2600 gas)

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

### If prioritizing standalone Spoke → Hub flexibility: **Option E (Hybrid)**

**Option E** is a good choice if:

- You want to minimize changes to Universal_SpokePool
- External adapter contracts are acceptable
- Hub → Spoke architecture is not changing

Reasons:

1. **Backward Compatibility**: Maintains existing CCTP and OFT paths with no changes
2. **Incremental Adoption**: New bridges can be added without modifying core contract
3. **Gas Efficiency**: Common paths (USDC, OFT tokens) remain optimized
4. **Security**: Adapters are isolated; bugs don't affect built-in bridges
5. **Operational Flexibility**: Token-to-adapter mapping can be updated via HubPool governance
6. **Reusability**: Standard adapters (OP, Arbitrum) deployed once, used by many SpokePools

### If prioritizing architectural symmetry with Hub → Spoke: **Option D (ERC-7201 Plugins)**

**Option D** is the better choice if:

- Hub → Spoke adapters will also use ERC-7201 namespaced storage
- You want all bridge state to live in pool contracts (no external adapter state)
- Unified governance model is important
- Gas efficiency is a priority (no token transfers to external contracts)

Reasons:

1. **Bidirectional Symmetry**: Same pattern for Hub → Spoke and Spoke → Hub
2. **Unified State Management**: All config in HubPool/SpokePool via ERC-7201 namespaces
3. **Single Governance Model**: HubPool owner controls everything via relay messages
4. **Gas Efficient**: No intermediate token transfers; delegatecall is cheap
5. **No External Contracts**: Fewer contracts to deploy, audit, and track ownership
6. **Future-Proof**: ERC-7201 is the emerging standard for upgradeable storage

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
| Gas Efficiency        | Medium   | Medium   | High     | High     | High (common) / Medium (custom) |
| Audit Complexity      | Medium   | High     | Low      | Medium   | Medium                          |
| Upgrade Path          | Easy     | Hard     | Redeploy | Easy     | Easy                            |
| Implementation Effort | Medium   | High     | Low      | Medium   | Medium                          |
| Risk Profile          | Medium   | High     | Low      | Low-Med  | Low-Medium                      |
| Backward Compatible   | Yes      | No       | No       | Yes      | Yes                             |
| State Management      | External | External | Compile  | ERC-7201 | Mixed                           |
| Hub↔Spoke Symmetry    | No       | No       | No       | **Yes**  | No                              |

---

## Bidirectional Considerations

The discussion so far has focused on **Spoke → Hub** (returning tokens to L1). However, **Hub → Spoke** (sending tokens to L2) also uses adapters, and the two directions should ideally share a consistent architecture.

### Current Hub → Spoke Architecture

HubPool uses L1 adapters (e.g., `Arbitrum_Adapter`, `OP_Adapter`) to send tokens and relay messages to SpokePools:

```solidity
// In HubPool
function _relayMessage(address adapter, address target, bytes memory message) internal {
  // Adapters are called via delegatecall - they execute in HubPool's context
  (bool success, ) = adapter.delegatecall(
    abi.encodeWithSelector(AdapterInterface.relayMessage.selector, target, message)
  );
}
```

**Key constraint**: Current L1 adapters are stateless. Any configuration (bridge addresses, gas limits) must be:

- Hardcoded as immutables in the adapter
- Passed in via function parameters
- Stored in HubPool's main storage (not ideal)

### The Symmetry Argument for Option D

If we adopt **ERC-7201 namespaced storage for Hub → Spoke adapters**, then using the same pattern for Spoke → Hub (Option D) creates architectural symmetry:

```
Hub → Spoke:
  HubPool.delegatecall(adapter)
    → Adapter reads config from HubPool storage (ERC-7201 namespace)
    → Adapter bridges tokens to SpokePool

Spoke → Hub:
  SpokePool.delegatecall(plugin)
    → Plugin reads config from SpokePool storage (ERC-7201 namespace)
    → Plugin bridges tokens to HubPool
```

**Benefits of symmetry**:

1. **One mental model**: Developers learn one pattern for both directions
2. **Shared tooling**: Same ERC-7201 storage inspection tools work for both
3. **Consistent governance**: HubPool owner configures both sides via relay messages
4. **No external contracts**: All state lives in HubPool/SpokePool (no separate adapter ownership)

### State Ownership Summary

| Direction       | Option A (External Adapters)      | Option D (ERC-7201 Plugins)              |
| --------------- | --------------------------------- | ---------------------------------------- |
| **Hub → Spoke** | Adapter owns state (or stateless) | HubPool owns state in namespaced slots   |
| **Spoke → Hub** | Adapter owns state                | SpokePool owns state in namespaced slots |
| **Admin**       | Each adapter has separate owner   | HubPool owner controls all via relay     |
| **Upgrade**     | Replace adapter contract          | Replace plugin implementation address    |

### Recommendation Update

Given the bidirectional nature of the system, **Option D with ERC-7201** becomes more attractive because:

1. It aligns with the proposed approach for Hub → Spoke adapters
2. All bridge configuration state lives in the pool contracts
3. Single governance model (HubPool owner) for both directions
4. No proliferation of external adapter contracts with separate ownership

If the team is already planning to use HubPool storage + ERC-7201 for Hub → Spoke adapters, **Option D should be strongly considered** for Spoke → Hub to maintain architectural consistency.

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

5. **Hub → Spoke Alignment**: Should we commit to ERC-7201 for Hub → Spoke adapters first, then design Spoke → Hub to match? Or design both directions together?

6. **Migration Path**: For existing chain-specific SpokePools (OP_SpokePool, Arbitrum_SpokePool), should they be migrated to the new Universal_SpokePool + plugin architecture, or maintained separately?
