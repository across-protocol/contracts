# SpokePool Plugin Architecture Options

## Problem Statement

The current Across architecture requires chain-specific SpokePool implementations (`OP_SpokePool`, `Arbitrum_SpokePool`, `Universal_SpokePool`, etc.) because of two fundamental differences across chains:

### 1. Message Receiving (Hub → Spoke)

Different chains have different ways to verify that a message came from HubPool:

- **OP Stack chains**: CrossDomainMessenger with `xDomainMessageSender()`
- **Arbitrum**: Inbox aliasing where HubPool's address is deterministically modified
- **Alt L1s/Future chains**: Helios light client proofs, Hyperlane, or other verification methods

### 2. Token Bridging (Spoke → Hub)

Different chains have different canonical bridges for returning tokens to L1:

- **OP Stack**: L2StandardBridge / OptimismPortal
- **Arbitrum**: L2GatewayRouter / ArbSys
- **Universal**: CCTP (USDC), OFT (LayerZero tokens)
- **Custom**: Chain-specific bridges (e.g., MegaETH requiring OP native bridge)

### Current Pain Points

1. **Deployment fragmentation**: MegaETH needed OP_SpokePool instead of Universal_SpokePool because it required the OP native bridge
2. **Code duplication**: Each chain-specific SpokePool duplicates 95%+ of the core logic
3. **Maintenance burden**: Bug fixes and features must be propagated to all implementations
4. **New chain friction**: Supporting a new L2 requires creating a new SpokePool variant

### Goal

Create a **single SpokePool implementation** that works on all chains by making both message receiving and token bridging pluggable via ERC-7201 namespaced storage plugins.

## Current Architecture

### Message Receiving (Hub → Spoke)

Each chain-specific SpokePool overrides `_requireAdminSender()` differently:

```solidity
// OP_SpokePool
function _requireAdminSender() internal view override {
  require(msg.sender == address(messenger) && messenger.xDomainMessageSender() == crossDomainAdmin);
}

// Arbitrum_SpokePool
function _requireAdminSender() internal view override {
  require(msg.sender == AddressAliasHelper.applyL1ToL2Alias(crossDomainAdmin));
}

// Universal_SpokePool (no cross-chain messages - admin only)
function _requireAdminSender() internal view override {
  require(msg.sender == owner());
}
```

### Token Bridging (Spoke → Hub)

Each chain-specific SpokePool overrides `_bridgeTokensToHubPool()` differently:

```solidity
// OP_SpokePool
function _bridgeTokensToHubPool(uint256 amount, address token) internal override {
  IL2ERC20Bridge(Lib_PredeployAddresses.L2_STANDARD_BRIDGE).withdrawTo(...);
}

// Arbitrum_SpokePool
function _bridgeTokensToHubPool(uint256 amount, address token) internal override {
  ArbitrumL2ERC20GatewayLike(l2GatewayRouter).outboundTransfer(...);
}

// Universal_SpokePool
function _bridgeTokensToHubPool(uint256 amount, address token) internal override {
  if (_isCCTPEnabled() && token == usdcToken) { _transferUsdc(...); }
  else if (_getOftMessenger(token) != address(0)) { _fundedTransferViaOft(...); }
  else { revert NotImplemented(); }
}
```

### Why This Is Problematic

1. **Hard-coded paths**: Each SpokePool can only use the bridges compiled into it
2. **No runtime flexibility**: MegaETH needed OP_SpokePool, not Universal_SpokePool
3. **N×M problem**: N chains × M bridge types = explosion of implementations
4. **Scattered upgrades**: Fixing a bug requires upgrading every SpokePool variant

---

## Design Options

> **Note**: The options below focus primarily on Spoke → Hub token bridging. However, the same architectural patterns apply to Hub → Spoke message receiving. The recommended approach (Option D) handles both directions with a unified plugin model. See [universal-spokepool-erc7201-plugins.md](./universal-spokepool-erc7201-plugins.md) for the complete design including message receiver plugins.

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

### Option E: Hybrid Approach

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

### Primary Recommendation: **Option D (ERC-7201 Plugins)**

**Option D with ERC-7201 namespaced storage** is the recommended approach because it enables the expanded goal: **a single SpokePool implementation that works on all chains**.

With Option D, we can make both directions pluggable:

1. **Message Receiving (Hub → Spoke)**: `IMessageReceiverPlugin` implementations

   - `HeliosMessageReceiver` - Light client proofs for alt L1s
   - `OPCrossDomainReceiver` - OP Stack CrossDomainMessenger
   - `ArbitrumInboxReceiver` - Arbitrum address aliasing
   - `AdminOnlyReceiver` - Direct admin control (fallback/bootstrap)

2. **Token Bridging (Spoke → Hub)**: `IBridgePlugin` implementations
   - `CCTPBridgePlugin` - Circle CCTP for USDC
   - `OFTBridgePlugin` - LayerZero OFT
   - `OPStandardBridgePlugin` - OP L2StandardBridge
   - `ArbitrumGatewayPlugin` - Arbitrum L2GatewayRouter

**Why Option D enables a single SpokePool**:

1. **Eliminates chain-specific overrides**: `_requireAdminSender()` and `_bridgeTokensToHubPool()` become plugin dispatchers
2. **Runtime configuration**: HubPool governance can configure plugins without SpokePool upgrade
3. **Unified state management**: All plugin config lives in SpokePool via ERC-7201 namespaces
4. **No code duplication**: One SpokePool.sol, many plugin implementations
5. **Future-proof**: New chains only need new plugins, not new SpokePool variants

See [universal-spokepool-erc7201-plugins.md](./universal-spokepool-erc7201-plugins.md) for the complete implementation design.

### Alternative: **Option E (Hybrid)** for incremental adoption

**Option E** is a reasonable fallback if:

- You want to minimize changes to existing SpokePools
- External adapter contracts are acceptable
- You're not ready to commit to the full plugin architecture

However, Option E only addresses Spoke → Hub bridging. It doesn't solve the message receiving problem, so chain-specific SpokePools would still be needed.

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

## Bidirectional Architecture

With the expanded scope, we're not just addressing Spoke → Hub bridging—we're making the entire SpokePool pluggable in both directions to eliminate all chain-specific implementations.

### The Two Plugin Types

**1. Message Receiver Plugin (Hub → Spoke) — ONE per SpokePool**

Each SpokePool has exactly **one** message receiver plugin. This makes sense because a chain has one canonical way to receive cross-chain messages from L1.

```solidity
interface IMessageReceiverPlugin {
  /// @notice Check if the current call is from an authorized admin source
  /// @return True if the sender is authorized
  function isAuthorizedSender() external view returns (bool);
}

// Storage: single plugin address
address public messageReceiverPlugin;
```

Implementations (pick ONE for the chain):

- `HeliosMessageReceiver` - Verifies Helios light client proofs
- `OPCrossDomainReceiver` - Checks CrossDomainMessenger.xDomainMessageSender()
- `ArbitrumInboxReceiver` - Verifies address aliasing from Arbitrum Inbox
- `AdminOnlyReceiver` - Direct admin control (for bootstrap/fallback)

**2. Bridge Plugins (Spoke → Hub) — MANY per SpokePool (token → plugin)**

Each SpokePool can have **multiple** bridge plugins, with each token mapped to exactly one plugin. Different tokens on the same chain use different bridges.

```solidity
interface IBridgePlugin {
  function bridge(address l2Token, address to, uint256 amount) external;
  function quoteFee(address l2Token, uint256 amount) external view returns (uint256);
}

// Storage: multiple plugins, token routing
mapping(bytes4 pluginId => address implementation) public bridgePlugins;
mapping(address l2Token => bytes4 pluginId) public tokenBridgeTypes;
```

Implementations (can use multiple, one per token):

- `CCTPBridgePlugin` - Circle CCTP for USDC
- `OFTBridgePlugin` - LayerZero OFT tokens
- `OPStandardBridgePlugin` - OP L2StandardBridge
- `ArbitrumGatewayPlugin` - Arbitrum L2GatewayRouter

### Architectural Symmetry

```
┌─────────────────────────────────────────────────────────────────────┐
│                             HubPool                                   │
│  ERC-7201: "across.adapter.op"     - L1 bridge config                │
│  ERC-7201: "across.adapter.arb"    - L1 bridge config                │
│                                                                       │
│  delegatecall → L1 Adapter → sends tokens/messages to SpokePool      │
└─────────────────────────────────────────────────────────────────────┘
                                   ↓
                        Cross-chain message/tokens
                                   ↓
┌─────────────────────────────────────────────────────────────────────┐
│                            SpokePool                                  │
│                                                                       │
│  Plugin Registry:                                                     │
│    - messageReceiverPlugin: address     ←── ONE (1:1)                │
│    - bridgePlugins: pluginId → impl     ←── MANY registered          │
│    - tokenBridgeTypes: token → pluginId ←── token routing (1:N)      │
│                                                                       │
│  ERC-7201 Namespaces (only active plugins use their storage):        │
│    "across.receiver.op-messenger"  - CDM config (if OP receiver)     │
│    "across.bridge.cctp"            - CCTP config (if CCTP plugin)    │
│    "across.bridge.oft"             - OFT config (if OFT plugin)      │
│    "across.bridge.op-standard"     - L2Bridge config (if OP plugin)  │
│                                                                       │
│  _requireAdminSender() → delegatecall messageReceiverPlugin (1)      │
│  _bridgeTokensToHubPool(token) → lookup plugin → delegatecall (N)    │
└─────────────────────────────────────────────────────────────────────┘
```

### Cardinality Summary

| Plugin Type      | Cardinality | Rationale                                    |
| ---------------- | ----------- | -------------------------------------------- |
| Message Receiver | 1:1         | One canonical L1→L2 messaging path per chain |
| Bridge Plugins   | 1:N         | Different tokens use different L2→L1 bridges |

### Benefits of the Expanded Architecture

1. **Single SpokePool implementation**: Eliminates OP_SpokePool, Arbitrum_SpokePool, Universal_SpokePool, etc.
2. **Runtime configuration**: New chains only need plugin deployment + configuration
3. **Unified governance**: HubPool owner configures everything via relay messages
4. **Future-proof**: Helios, Hyperlane, or any new verification method = just a new plugin
5. **Reduced audit surface**: One SpokePool to audit, plus isolated plugins

### State Ownership Summary

| Component               | What It Stores                              | Who Configures It        |
| ----------------------- | ------------------------------------------- | ------------------------ |
| **SpokePool Core**      | Plugin registry, deposits, fills            | HubPool via relay        |
| **Message Receiver**    | Chain-specific verification config          | HubPool via relay        |
| **Bridge Plugin**       | Bridge addresses, gas limits, token mapping | HubPool via relay        |
| **ERC-7201 Namespaces** | Plugin-specific storage (isolated)          | Plugin.configure() calls |

---

## Open Questions

1. **Fee Handling**: How should native bridge fees be funded?

   - SpokePool holds ETH buffer (current approach for OFT)
   - Fee pulled from relayer refund
   - Bridge plugin quotes fee, SpokePool provides it

2. **Bootstrap Problem**: How does the first message receiver get configured?

   - Deploy SpokePool with admin-controlled receiver initially
   - Admin configures the real receiver (e.g., OP CrossDomainMessenger)
   - Future config changes flow through HubPool governance

3. **Plugin Governance**: Should plugin changes require:

   - HubPool governance vote?
   - Timelock delay?
   - Multi-sig approval?

4. **Plugin Verification**: How to ensure plugin correctness?

   - Whitelist of approved plugin implementations?
   - Integration test requirements before deployment?
   - Formal verification of ERC-7201 storage isolation?

5. **Migration Path**: For existing chain-specific SpokePools:

   - Option A: Migrate to new pluggable SpokePool (requires upgrade)
   - Option B: Maintain legacy SpokePools, use pluggable SpokePool for new chains only
   - Option C: Gradual migration as SpokePools need upgrades anyway

6. **HubPool Adapter Alignment**: Should HubPool L1 adapters also move to ERC-7201?

   - Currently they're stateless with immutables
   - Would provide full bidirectional symmetry
   - Adds complexity to HubPool upgrades

7. **Fallback Behavior**: What happens if no message receiver is configured?
   - Revert all admin calls?
   - Fall back to direct admin (owner()) control?
   - Both (configurable)?
