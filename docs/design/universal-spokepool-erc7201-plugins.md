# Unified SpokePool: Fully Pluggable Architecture (Option D)

## Overview

This document describes a fully pluggable SpokePool architecture where both communication directions—Hub → Spoke (message receiving) and Spoke → Hub (token bridging)—are configurable via ERC-7201 namespaced plugins.

This eliminates the need for chain-specific SpokePool implementations (`Universal_SpokePool`, `OP_SpokePool`, `Arbitrum_SpokePool`, etc.) in favor of a single, configurable `SpokePool` contract.

**Related**: See `universal-spokepool-bridge-adapters-options.md` for comparison with alternative approaches.

## Goals

1. **Single SpokePool implementation** that works on any chain
2. **Pluggable message receiving** (Hub → Spoke): Helios proofs, cross-domain messengers, Arbitrum inbox, etc.
3. **Pluggable token bridging** (Spoke → Hub): CCTP, OFT, OP bridge, Arbitrum gateway, etc.
4. **ERC-7201 namespaced storage** for all plugin state to prevent collisions
5. **Unified governance** through HubPool for all configuration

## Architecture

### Current State (Chain-Specific Implementations)

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                Chain-Specific Implementations            │
                    │                                                         │
SpokePool (base) ───┼──► Universal_SpokePool   (Helios + CCTP/OFT)           │
                    │                                                         │
                    ├──► OP_SpokePool          (CrossDomainMessenger + OP Bridge)
                    │                                                         │
                    ├──► Arbitrum_SpokePool    (Arbitrum Inbox + Gateway)     │
                    │                                                         │
                    ├──► Polygon_SpokePool     (FxChild + PoS Bridge)         │
                    │                                                         │
                    └──► [New chain = New contract]                           │
                                                                              │
```

**Problems:**

- Each chain requires a new SpokePool implementation
- Core logic (deposits, fills, relays) is duplicated
- Adding bridge support requires modifying contracts
- Maintenance burden grows with each new chain

### Proposed State (Fully Pluggable)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                   SpokePool                                      │
│                        (single implementation, fully pluggable)                  │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                        Core Protocol Logic                               │   │
│  │  - Deposits (depositV3, unsafeDeposit, depositNow)                      │   │
│  │  - Fills (fillV3Relay, fillRelayWithUpdatedDeposit)                     │   │
│  │  - Slow fills (requestSlowFill, executeSlowRelayLeaf)                   │   │
│  │  - Root bundles (relayRootBundle, executeRelayerRefundLeaf)             │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                     Message Receiver Plugin                              │   │
│  │  Handles: Hub → Spoke communication                                      │   │
│  │                                                                          │   │
│  │  Options:                                                                │   │
│  │  - HeliosMessageReceiver (storage proofs via light client)              │   │
│  │  - OPCrossDomainReceiver (Optimism/Base CrossDomainMessenger)           │   │
│  │  - ArbitrumInboxReceiver (Arbitrum L1→L2 messaging)                     │   │
│  │  - PolygonFxReceiver (Polygon FxChild)                                  │   │
│  │  - AdminOnlyReceiver (simple admin check, for testing)                  │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                      Bridge Plugins (per-token)                          │   │
│  │  Handles: Spoke → Hub token transfers                                    │   │
│  │                                                                          │   │
│  │  Options:                                                                │   │
│  │  - CCTPBridgePlugin (Circle USDC)                                       │   │
│  │  - OFTBridgePlugin (LayerZero OFT)                                      │   │
│  │  - OPStandardBridgePlugin (Optimism/Base native bridge)                 │   │
│  │  - ArbitrumGatewayPlugin (Arbitrum L2→L1 gateway)                       │   │
│  │  - PolygonPoSBridgePlugin (Polygon PoS bridge)                          │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                      ERC-7201 Namespaced Storage                         │   │
│  │                                                                          │   │
│  │  Each plugin has isolated storage:                                       │   │
│  │  - across.message-receiver.helios     → Helios config                   │   │
│  │  - across.message-receiver.op         → CrossDomainMessenger config     │   │
│  │  - across.bridge-plugin.cctp          → CCTP config                     │   │
│  │  - across.bridge-plugin.oft           → OFT config                      │   │
│  │  - across.bridge-plugin.op-standard   → OP bridge config                │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Example Configurations

**Optimism/Base:**

```
Message Receiver: OPCrossDomainReceiver
Bridge Plugins:
  - WETH → OPStandardBridgePlugin (unwrap + native ETH bridge)
  - USDC → CCTPBridgePlugin
  - Other tokens → OPStandardBridgePlugin
```

**Arbitrum:**

```
Message Receiver: ArbitrumInboxReceiver
Bridge Plugins:
  - USDC → CCTPBridgePlugin
  - Other tokens → ArbitrumGatewayPlugin
```

**MegaETH (OP Stack + Helios):**

```
Message Receiver: HeliosMessageReceiver
Bridge Plugins:
  - WETH → OPStandardBridgePlugin
  - USDC → CCTPBridgePlugin
  - Other tokens → OFTBridgePlugin
```

**New Alt-L1:**

```
Message Receiver: HeliosMessageReceiver (or custom)
Bridge Plugins:
  - All tokens → OFTBridgePlugin
```

## Technical Specification

### Interface Definitions

#### Message Receiver Plugin Interface

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title IMessageReceiverPlugin
/// @notice Interface for plugins that handle Hub → Spoke message authentication and execution
interface IMessageReceiverPlugin {
  /// @notice Returns the unique identifier for this plugin type
  function pluginId() external pure returns (bytes4);

  /// @notice Verify that a caller is authorized to execute admin functions
  /// @param caller The address calling the admin function
  /// @param authData Optional authentication data (e.g., proof data for Helios)
  /// @return True if the caller is authorized
  /// @dev Called via delegatecall from SpokePool
  function isAuthorizedAdmin(address caller, bytes calldata authData) external view returns (bool);

  /// @notice Execute an authenticated message from HubPool
  /// @param message The message calldata to execute
  /// @param authData Authentication/proof data specific to this receiver type
  /// @dev Called via delegatecall from SpokePool
  function executeMessage(bytes calldata message, bytes calldata authData) external;

  /// @notice Configure the plugin
  /// @param configData ABI-encoded configuration parameters
  /// @dev Called via delegatecall from SpokePool
  function configure(bytes calldata configData) external;
}
```

#### Bridge Plugin Interface

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title IBridgePlugin
/// @notice Interface for plugins that handle Spoke → Hub token bridging
interface IBridgePlugin {
  /// @notice Returns the unique identifier for this plugin type
  function pluginId() external pure returns (bytes4);

  /// @notice Bridge tokens to L1
  /// @param l2Token The L2 token address to bridge
  /// @param to Recipient address on L1
  /// @param amount Amount to bridge
  /// @dev Called via delegatecall from SpokePool
  function bridge(address l2Token, address to, uint256 amount) external;

  /// @notice Configure the plugin
  /// @param configData ABI-encoded configuration parameters
  /// @dev Called via delegatecall from SpokePool
  function configure(bytes calldata configData) external;
}
```

### SpokePool Implementation

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SpokePoolBase } from "./SpokePoolBase.sol";
import { IMessageReceiverPlugin } from "./interfaces/IMessageReceiverPlugin.sol";
import { IBridgePlugin } from "./interfaces/IBridgePlugin.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SpokePool
/// @notice Fully pluggable SpokePool with configurable message receiving and token bridging
contract SpokePool is SpokePoolBase {
  using SafeERC20 for IERC20;

  // ═══════════════════════════════════════════════════════════════════════════
  // ERRORS
  // ═══════════════════════════════════════════════════════════════════════════

  error MessageReceiverNotSet();
  error BridgePluginNotRegistered(bytes4 pluginId);
  error NoBridgeConfigured(address token);
  error PluginCallFailed(bytes4 pluginId);
  error NotAuthorizedAdmin();
  error InvalidPluginId();

  // ═══════════════════════════════════════════════════════════════════════════
  // EVENTS
  // ═══════════════════════════════════════════════════════════════════════════

  event MessageReceiverSet(address indexed implementation);
  event BridgePluginSet(bytes4 indexed pluginId, address indexed implementation);
  event TokenBridgeTypeSet(address indexed l2Token, bytes4 indexed pluginId);
  event PluginConfigured(bytes4 indexed pluginId, bytes configData);
  event MessageExecuted(bytes32 indexed messageHash);

  // ═══════════════════════════════════════════════════════════════════════════
  // STORAGE
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice The message receiver plugin implementation
  address public messageReceiverPlugin;

  /// @notice Bridge plugin implementations by plugin ID
  mapping(bytes4 pluginId => address implementation) public bridgePlugins;

  /// @notice Bridge plugin type assigned to each token
  mapping(address l2Token => bytes4 pluginId) public tokenBridgeTypes;

  // ═══════════════════════════════════════════════════════════════════════════
  // MODIFIERS
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice Verifies the caller is an authorized admin via the message receiver plugin
  /// @param authData Optional authentication data for the receiver plugin
  modifier onlyAdmin(bytes memory authData) {
    _requireAdminSender(msg.sender, authData);
    _;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // EXTERNAL FUNCTIONS - MESSAGE RECEIVING
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice Execute a message from HubPool
  /// @param message The message calldata to execute
  /// @param authData Authentication/proof data for the message receiver plugin
  /// @dev The message receiver plugin verifies authenticity and executes
  function executeMessage(bytes calldata message, bytes calldata authData) external nonReentrant {
    address receiver = messageReceiverPlugin;
    if (receiver == address(0)) revert MessageReceiverNotSet();

    (bool success, bytes memory returnData) = receiver.delegatecall(
      abi.encodeCall(IMessageReceiverPlugin.executeMessage, (message, authData))
    );

    if (!success) {
      _revertWithData(returnData);
    }

    emit MessageExecuted(keccak256(message));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // EXTERNAL FUNCTIONS - ADMIN (via HubPool)
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice Set the message receiver plugin
  /// @param implementation Address of the message receiver plugin contract
  function setMessageReceiverPlugin(address implementation) external onlyAdmin("") {
    messageReceiverPlugin = implementation;
    emit MessageReceiverSet(implementation);
  }

  /// @notice Register a bridge plugin implementation
  /// @param pluginId Unique identifier for the plugin type
  /// @param implementation Address of the plugin contract
  function setBridgePlugin(bytes4 pluginId, address implementation) external onlyAdmin("") {
    if (pluginId == bytes4(0)) revert InvalidPluginId();
    bridgePlugins[pluginId] = implementation;
    emit BridgePluginSet(pluginId, implementation);
  }

  /// @notice Assign a bridge plugin to a token
  /// @param l2Token The L2 token address
  /// @param pluginId The plugin type to use for this token (0 to remove)
  function setTokenBridgeType(address l2Token, bytes4 pluginId) external onlyAdmin("") {
    if (pluginId != bytes4(0) && bridgePlugins[pluginId] == address(0)) {
      revert BridgePluginNotRegistered(pluginId);
    }
    tokenBridgeTypes[l2Token] = pluginId;
    emit TokenBridgeTypeSet(l2Token, pluginId);
  }

  /// @notice Configure a plugin's storage via delegatecall
  /// @param pluginId The plugin to configure
  /// @param configData ABI-encoded configuration data
  function configurePlugin(bytes4 pluginId, bytes calldata configData) external onlyAdmin("") {
    address plugin = _getPluginAddress(pluginId);

    (bool success, bytes memory returnData) = plugin.delegatecall(
      abi.encodeCall(IBridgePlugin.configure, (configData))
    );

    if (!success) {
      _revertWithData(returnData);
    }

    emit PluginConfigured(pluginId, configData);
  }

  /// @notice Configure the message receiver plugin
  /// @param configData ABI-encoded configuration data
  function configureMessageReceiver(bytes calldata configData) external onlyAdmin("") {
    address receiver = messageReceiverPlugin;
    if (receiver == address(0)) revert MessageReceiverNotSet();

    (bool success, bytes memory returnData) = receiver.delegatecall(
      abi.encodeCall(IMessageReceiverPlugin.configure, (configData))
    );

    if (!success) {
      _revertWithData(returnData);
    }

    emit PluginConfigured(IMessageReceiverPlugin(receiver).pluginId(), configData);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // INTERNAL FUNCTIONS
  // ═══════════════════════════════════════════════════════════════════════════

  /// @notice Bridge tokens back to HubPool
  /// @param amountToReturn Amount to bridge
  /// @param l2TokenAddress L2 token to bridge
  function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
    bytes4 pluginId = tokenBridgeTypes[l2TokenAddress];
    if (pluginId == bytes4(0)) revert NoBridgeConfigured(l2TokenAddress);

    address plugin = bridgePlugins[pluginId];
    if (plugin == address(0)) revert BridgePluginNotRegistered(pluginId);

    (bool success, bytes memory returnData) = plugin.delegatecall(
      abi.encodeCall(IBridgePlugin.bridge, (l2TokenAddress, hubPool, amountToReturn))
    );

    if (!success) {
      _revertWithData(returnData);
    }
  }

  /// @notice Verify caller is authorized admin
  /// @param caller The address to verify
  /// @param authData Authentication data for the receiver plugin
  function _requireAdminSender(address caller, bytes memory authData) internal view {
    address receiver = messageReceiverPlugin;

    // During initial setup, allow deployer to configure
    if (receiver == address(0)) {
      // Only allow if this is the first call to set up the receiver
      // After receiver is set, all admin calls go through it
      revert MessageReceiverNotSet();
    }

    // Use staticcall for view function
    (bool success, bytes memory result) = receiver.staticcall(
      abi.encodeCall(IMessageReceiverPlugin.isAuthorizedAdmin, (caller, authData))
    );

    if (!success || !abi.decode(result, (bool))) {
      revert NotAuthorizedAdmin();
    }
  }

  /// @notice Get plugin address, checking both bridge plugins and message receiver
  function _getPluginAddress(bytes4 pluginId) internal view returns (address) {
    // Check if it's the message receiver
    address receiver = messageReceiverPlugin;
    if (receiver != address(0)) {
      try IMessageReceiverPlugin(receiver).pluginId() returns (bytes4 receiverId) {
        if (receiverId == pluginId) return receiver;
      } catch {}
    }

    // Otherwise look in bridge plugins
    address bridge = bridgePlugins[pluginId];
    if (bridge == address(0)) revert BridgePluginNotRegistered(pluginId);
    return bridge;
  }

  /// @notice Revert with return data from failed delegatecall
  function _revertWithData(bytes memory returnData) internal pure {
    if (returnData.length > 0) {
      assembly {
        revert(add(returnData, 32), mload(returnData))
      }
    }
    revert("Plugin call failed");
  }
}
```

### Message Receiver Plugins

#### Helios Message Receiver (Storage Proofs)

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IMessageReceiverPlugin } from "../interfaces/IMessageReceiverPlugin.sol";

interface IHelios {
  function getStorageSlot(uint256 blockNumber, address target, bytes32 slot) external view returns (bytes32);
}

/// @title HeliosMessageReceiver
/// @notice Message receiver using Helios light client for storage proof verification
contract HeliosMessageReceiver is IMessageReceiverPlugin {
  // ═══════════════════════════════════════════════════════════════════════════
  // ERC-7201 STORAGE
  // ═══════════════════════════════════════════════════════════════════════════

  /// @custom:storage-location erc7201:across.message-receiver.helios
  struct HeliosStorage {
    address helios; // Helios light client address
    address hubPoolStore; // HubPoolStore contract on L1
    address hubPool; // HubPool address (for admin verification)
    uint256 currentNonce; // Next expected message nonce
    mapping(uint256 => bool) executedMessages; // Replay protection
  }

  // keccak256(abi.encode(uint256(keccak256("across.message-receiver.helios")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant STORAGE_SLOT = 0x1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a00;

  function _getStorage() private pure returns (HeliosStorage storage $) {
    assembly {
      $.slot := STORAGE_SLOT
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PLUGIN INTERFACE
  // ═══════════════════════════════════════════════════════════════════════════

  function pluginId() external pure override returns (bytes4) {
    return bytes4(keccak256("across.message-receiver.helios"));
  }

  function isAuthorizedAdmin(address caller, bytes calldata authData) external view override returns (bool) {
    HeliosStorage storage $ = _getStorage();

    // For Helios, admin calls come through executeMessage, not direct calls
    // So we verify the message was properly authenticated via storage proof
    // Direct admin calls are not supported - return false
    if (authData.length == 0) return false;

    // If authData provided, verify it's a valid storage proof
    // This is called during executeMessage flow
    (uint256 blockNumber, bytes32 expectedSlot) = abi.decode(authData, (uint256, bytes32));

    bytes32 slotValue = IHelios($.helios).getStorageSlot(blockNumber, $.hubPoolStore, expectedSlot);
    return slotValue != bytes32(0);
  }

  function executeMessage(bytes calldata message, bytes calldata authData) external override {
    HeliosStorage storage $ = _getStorage();

    // Decode auth data
    (uint256 messageNonce, uint256 blockNumber) = abi.decode(authData, (uint256, uint256));

    // Check replay protection
    require(!$.executedMessages[messageNonce], "Already executed");

    // Compute expected storage slot
    bytes32 slotKey = keccak256(abi.encode(messageNonce, uint256(0))); // Assuming slot 0 for messages mapping
    bytes32 expectedSlotValue = keccak256(message);

    // Verify against Helios
    bytes32 actualSlotValue = IHelios($.helios).getStorageSlot(blockNumber, $.hubPoolStore, slotKey);
    require(actualSlotValue == expectedSlotValue, "Invalid storage proof");

    // Mark as executed
    $.executedMessages[messageNonce] = true;

    // Execute the message via delegatecall to self (SpokePool)
    (bool success, bytes memory returnData) = address(this).delegatecall(message);
    require(success, string(returnData));
  }

  function configure(bytes calldata configData) external override {
    HeliosStorage storage $ = _getStorage();

    (address helios, address hubPoolStore, address hubPool) = abi.decode(configData, (address, address, address));

    $.helios = helios;
    $.hubPoolStore = hubPoolStore;
    $.hubPool = hubPool;
  }
}
```

#### OP CrossDomain Message Receiver

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IMessageReceiverPlugin } from "../interfaces/IMessageReceiverPlugin.sol";

interface ICrossDomainMessenger {
  function xDomainMessageSender() external view returns (address);
}

/// @title OPCrossDomainReceiver
/// @notice Message receiver for OP Stack chains using CrossDomainMessenger
contract OPCrossDomainReceiver is IMessageReceiverPlugin {
  // ═══════════════════════════════════════════════════════════════════════════
  // ERC-7201 STORAGE
  // ═══════════════════════════════════════════════════════════════════════════

  /// @custom:storage-location erc7201:across.message-receiver.op-crossdomain
  struct OPCrossDomainStorage {
    address crossDomainMessenger; // L2 CrossDomainMessenger
    address hubPool; // HubPool address on L1
  }

  // keccak256(abi.encode(uint256(keccak256("across.message-receiver.op-crossdomain")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant STORAGE_SLOT = 0x2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b00;

  function _getStorage() private pure returns (OPCrossDomainStorage storage $) {
    assembly {
      $.slot := STORAGE_SLOT
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PLUGIN INTERFACE
  // ═══════════════════════════════════════════════════════════════════════════

  function pluginId() external pure override returns (bytes4) {
    return bytes4(keccak256("across.message-receiver.op-crossdomain"));
  }

  function isAuthorizedAdmin(address caller, bytes calldata) external view override returns (bool) {
    OPCrossDomainStorage storage $ = _getStorage();

    // Caller must be the CrossDomainMessenger
    if (caller != $.crossDomainMessenger) return false;

    // And the L1 sender must be HubPool
    address l1Sender = ICrossDomainMessenger($.crossDomainMessenger).xDomainMessageSender();
    return l1Sender == $.hubPool;
  }

  function executeMessage(bytes calldata message, bytes calldata) external override {
    OPCrossDomainStorage storage $ = _getStorage();

    // Verify caller is CrossDomainMessenger
    require(msg.sender == $.crossDomainMessenger, "Not CrossDomainMessenger");

    // Verify L1 sender is HubPool
    address l1Sender = ICrossDomainMessenger($.crossDomainMessenger).xDomainMessageSender();
    require(l1Sender == $.hubPool, "Not from HubPool");

    // Execute the message
    (bool success, bytes memory returnData) = address(this).delegatecall(message);
    require(success, string(returnData));
  }

  function configure(bytes calldata configData) external override {
    OPCrossDomainStorage storage $ = _getStorage();

    (address messenger, address hubPool) = abi.decode(configData, (address, address));

    $.crossDomainMessenger = messenger;
    $.hubPool = hubPool;
  }
}
```

#### Arbitrum Inbox Message Receiver

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IMessageReceiverPlugin } from "../interfaces/IMessageReceiverPlugin.sol";

interface IArbSys {
  function wasMyCallersAddressAliased() external view returns (bool);
  function myCallersAddressWithoutAliasing() external view returns (address);
}

/// @title ArbitrumInboxReceiver
/// @notice Message receiver for Arbitrum using L1→L2 address aliasing
contract ArbitrumInboxReceiver is IMessageReceiverPlugin {
  // Arbitrum's ArbSys precompile
  IArbSys constant ARB_SYS = IArbSys(address(100));

  // Address alias offset applied to L1 addresses
  uint160 constant OFFSET = uint160(0x1111000000000000000000000000000000001111);

  // ═══════════════════════════════════════════════════════════════════════════
  // ERC-7201 STORAGE
  // ═══════════════════════════════════════════════════════════════════════════

  /// @custom:storage-location erc7201:across.message-receiver.arbitrum
  struct ArbitrumStorage {
    address hubPool; // HubPool address on L1 (unaliased)
    address l1Adapter; // L1 Adapter address (unaliased)
  }

  // keccak256(abi.encode(uint256(keccak256("across.message-receiver.arbitrum")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant STORAGE_SLOT = 0x3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c00;

  function _getStorage() private pure returns (ArbitrumStorage storage $) {
    assembly {
      $.slot := STORAGE_SLOT
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PLUGIN INTERFACE
  // ═══════════════════════════════════════════════════════════════════════════

  function pluginId() external pure override returns (bytes4) {
    return bytes4(keccak256("across.message-receiver.arbitrum"));
  }

  function isAuthorizedAdmin(address caller, bytes calldata) external view override returns (bool) {
    ArbitrumStorage storage $ = _getStorage();

    // Check if caller's address was aliased (meaning it came from L1)
    if (!ARB_SYS.wasMyCallersAddressAliased()) return false;

    // Get the original L1 address
    address l1Sender = ARB_SYS.myCallersAddressWithoutAliasing();

    // Must be from HubPool or L1 Adapter
    return l1Sender == $.hubPool || l1Sender == $.l1Adapter;
  }

  function executeMessage(bytes calldata message, bytes calldata) external override {
    ArbitrumStorage storage $ = _getStorage();

    // Verify the call came from L1
    require(ARB_SYS.wasMyCallersAddressAliased(), "Not from L1");

    // Get unaliased sender
    address l1Sender = ARB_SYS.myCallersAddressWithoutAliasing();
    require(l1Sender == $.hubPool || l1Sender == $.l1Adapter, "Not authorized");

    // Execute the message
    (bool success, bytes memory returnData) = address(this).delegatecall(message);
    require(success, string(returnData));
  }

  function configure(bytes calldata configData) external override {
    ArbitrumStorage storage $ = _getStorage();

    (address hubPool, address l1Adapter) = abi.decode(configData, (address, address));

    $.hubPool = hubPool;
    $.l1Adapter = l1Adapter;
  }
}
```

#### Admin-Only Receiver (Testing/Simple Chains)

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IMessageReceiverPlugin } from "../interfaces/IMessageReceiverPlugin.sol";

/// @title AdminOnlyReceiver
/// @notice Simple message receiver that checks a single admin address
/// @dev For testing or chains where HubPool can call SpokePool directly
contract AdminOnlyReceiver is IMessageReceiverPlugin {
  // ═══════════════════════════════════════════════════════════════════════════
  // ERC-7201 STORAGE
  // ═══════════════════════════════════════════════════════════════════════════

  /// @custom:storage-location erc7201:across.message-receiver.admin-only
  struct AdminOnlyStorage {
    address admin;
  }

  // keccak256(abi.encode(uint256(keccak256("across.message-receiver.admin-only")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant STORAGE_SLOT = 0x4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d00;

  function _getStorage() private pure returns (AdminOnlyStorage storage $) {
    assembly {
      $.slot := STORAGE_SLOT
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PLUGIN INTERFACE
  // ═══════════════════════════════════════════════════════════════════════════

  function pluginId() external pure override returns (bytes4) {
    return bytes4(keccak256("across.message-receiver.admin-only"));
  }

  function isAuthorizedAdmin(address caller, bytes calldata) external view override returns (bool) {
    AdminOnlyStorage storage $ = _getStorage();
    return caller == $.admin;
  }

  function executeMessage(bytes calldata message, bytes calldata) external override {
    AdminOnlyStorage storage $ = _getStorage();
    require(msg.sender == $.admin, "Not admin");

    (bool success, bytes memory returnData) = address(this).delegatecall(message);
    require(success, string(returnData));
  }

  function configure(bytes calldata configData) external override {
    AdminOnlyStorage storage $ = _getStorage();
    $.admin = abi.decode(configData, (address));
  }
}
```

### Bridge Plugins

_(Bridge plugins remain the same as in the previous version - CCTPBridgePlugin, OFTBridgePlugin, OPStandardBridgePlugin, ArbitrumGatewayPlugin)_

See the "Bridge Plugins" section in the appendix for full implementations.

## Initialization Flow

### New SpokePool Deployment

```
1. Deploy SpokePool contract
   └─► SpokePool has no plugins configured yet

2. Deploy message receiver plugin (e.g., OPCrossDomainReceiver)
   └─► Stateless contract, just code

3. Deploy bridge plugins (e.g., CCTPBridgePlugin, OPStandardBridgePlugin)
   └─► Stateless contracts, just code

4. Initialize SpokePool (one-time setup, must be done by deployer or via initializer)
   ├─► setMessageReceiverPlugin(receiverAddress)
   └─► configureMessageReceiver(abi.encode(crossDomainMessenger, hubPool))

5. From HubPool (now that message receiver is configured):
   ├─► setBridgePlugin(CCTP_PLUGIN_ID, cctpPluginAddress)
   ├─► setBridgePlugin(OP_BRIDGE_PLUGIN_ID, opBridgePluginAddress)
   ├─► configurePlugin(CCTP_PLUGIN_ID, cctpConfig)
   ├─► configurePlugin(OP_BRIDGE_PLUGIN_ID, opBridgeConfig)
   ├─► setTokenBridgeType(USDC, CCTP_PLUGIN_ID)
   ├─► setTokenBridgeType(WETH, OP_BRIDGE_PLUGIN_ID)
   └─► setTokenBridgeType(DAI, OP_BRIDGE_PLUGIN_ID)
```

### Bootstrap Problem

There's a chicken-and-egg problem: you need a message receiver to authorize admin calls, but you need an admin call to set up the message receiver.

**Solutions:**

1. **Initializer pattern**: SpokePool has an `initialize()` function that can only be called once, which sets up the initial message receiver.

2. **Deployer privilege**: The deployer has a one-time privilege to set the message receiver before any other admin functions work.

3. **Constructor parameter**: Pass the initial message receiver address in the constructor.

**Recommended approach** (Initializer + Deployer):

```solidity
contract SpokePool is SpokePoolBase, Initializable {
  address private _initialAdmin;

  constructor() {
    _initialAdmin = msg.sender;
  }

  function initialize(address _messageReceiverPlugin, bytes calldata _receiverConfig) external initializer {
    require(msg.sender == _initialAdmin, "Not deployer");

    messageReceiverPlugin = _messageReceiverPlugin;

    if (_receiverConfig.length > 0) {
      (bool success, ) = _messageReceiverPlugin.delegatecall(
        abi.encodeCall(IMessageReceiverPlugin.configure, (_receiverConfig))
      );
      require(success, "Config failed");
    }

    // Clear initial admin - all future admin calls go through the plugin
    _initialAdmin = address(0);
  }
}
```

## Implementation Plan

### Phase 1: Core Infrastructure (Week 1-2)

**Deliverables:**

- [ ] `IMessageReceiverPlugin` interface
- [ ] `IBridgePlugin` interface
- [ ] Modified `SpokePool` with plugin registry
- [ ] `AdminOnlyReceiver` for testing
- [ ] Unit tests for plugin mechanics

**Tasks:**

1. Define interfaces in `contracts/interfaces/`
2. Implement plugin registry in SpokePool
3. Implement initialization flow with bootstrap solution
4. Implement `AdminOnlyReceiver` for local testing
5. Unit tests for:
   - Plugin registration
   - Admin authorization flow
   - Delegatecall execution
   - Storage isolation

### Phase 2: Message Receiver Plugins (Week 2-3)

**Deliverables:**

- [ ] `HeliosMessageReceiver`
- [ ] `OPCrossDomainReceiver`
- [ ] `ArbitrumInboxReceiver`
- [ ] Integration tests with mocked bridges

**Tasks:**

1. Port Helios logic from Universal_SpokePool to plugin
2. Port CrossDomainMessenger logic from Ovm_SpokePool to plugin
3. Port Arbitrum aliasing logic from Arbitrum_SpokePool to plugin
4. Integration tests with mock L1→L2 messaging

### Phase 3: Bridge Plugins (Week 3-4)

**Deliverables:**

- [ ] `CCTPBridgePlugin`
- [ ] `OFTBridgePlugin`
- [ ] `OPStandardBridgePlugin`
- [ ] `ArbitrumGatewayPlugin`
- [ ] Fork tests against live bridges

**Tasks:**

1. Extract CCTP logic to plugin
2. Extract OFT logic to plugin
3. Implement OP Standard Bridge plugin
4. Implement Arbitrum Gateway plugin
5. Fork tests for each plugin

### Phase 4: Testing & Migration Scripts (Week 4-5)

**Deliverables:**

- [ ] Full test coverage
- [ ] Gas benchmarks vs current implementation
- [ ] Deployment scripts
- [ ] Migration guide for existing SpokePools

**Tasks:**

1. End-to-end tests for each chain configuration
2. Gas comparison with current chain-specific SpokePools
3. Deployment scripts for each target chain
4. Document migration path for existing deployments

### Phase 5: Testnet Deployment (Week 5-6)

**Deliverables:**

- [ ] Testnet deployment on 3+ chains
- [ ] Validated MegaETH configuration
- [ ] Monitoring setup

**Tasks:**

1. Deploy to Sepolia (AdminOnly receiver for testing)
2. Deploy to OP Sepolia (OPCrossDomainReceiver + OP bridge plugins)
3. Deploy to Arbitrum Sepolia (ArbitrumInboxReceiver + Arb gateway plugin)
4. End-to-end bridge tests on testnets

### Phase 6: Audit & Mainnet (Week 6-8)

**Deliverables:**

- [ ] Completed audit
- [ ] Mainnet deployment
- [ ] Deprecation plan for old SpokePools

**Tasks:**

1. Security audit
2. Address findings
3. Phased mainnet rollout
4. Deprecate chain-specific SpokePool contracts

## Migration Strategy

### For Existing Deployments

**Option A: Upgrade in place** (if SpokePools are upgradeable)

1. Deploy new SpokePool implementation with plugin support
2. Deploy appropriate plugins
3. Upgrade proxy to new implementation
4. Configure plugins via HubPool

**Option B: Deploy new SpokePools**

1. Deploy new SpokePool with plugins
2. Migrate liquidity and state
3. Update HubPool to point to new SpokePools
4. Deprecate old SpokePools

### Configuration Mapping

| Current Contract    | Message Receiver      | Bridge Plugins               |
| ------------------- | --------------------- | ---------------------------- |
| Universal_SpokePool | HeliosMessageReceiver | CCTP + OFT                   |
| OP_SpokePool        | OPCrossDomainReceiver | OPStandardBridge + CCTP      |
| Arbitrum_SpokePool  | ArbitrumInboxReceiver | ArbitrumGateway + CCTP + OFT |
| Polygon_SpokePool   | PolygonFxReceiver     | PolygonPoSBridge + CCTP      |

## Security Considerations

### Plugin Trust Model

- Plugins execute via delegatecall in SpokePool context
- Plugin code is immutable (implementation address can change)
- All plugin configuration flows through HubPool governance
- Plugin storage is isolated via ERC-7201 namespaces

### Admin Authorization

- Message receiver plugin is the sole authority for admin checks
- Changing the message receiver requires existing admin authorization
- Bootstrap requires deployer privilege (one-time only)

### Storage Safety

- ERC-7201 namespaces prevent slot collisions
- Each plugin has a unique, documented storage slot
- Storage layout changes require new plugin deployment

## Appendix

### Storage Slot Reference

| Plugin                 | Namespace                                | Storage Slot  |
| ---------------------- | ---------------------------------------- | ------------- |
| HeliosMessageReceiver  | `across.message-receiver.helios`         | `0x1a2b3c...` |
| OPCrossDomainReceiver  | `across.message-receiver.op-crossdomain` | `0x2b3c4d...` |
| ArbitrumInboxReceiver  | `across.message-receiver.arbitrum`       | `0x3c4d5e...` |
| AdminOnlyReceiver      | `across.message-receiver.admin-only`     | `0x4d5e6f...` |
| CCTPBridgePlugin       | `across.bridge-plugin.cctp`              | `0x5e6f7a...` |
| OFTBridgePlugin        | `across.bridge-plugin.oft`               | `0x6f7a8b...` |
| OPStandardBridgePlugin | `across.bridge-plugin.op-standard`       | `0x7a8b9c...` |
| ArbitrumGatewayPlugin  | `across.bridge-plugin.arb-gateway`       | `0x8b9c0d...` |

_Note: Actual slot values must be computed using the ERC-7201 formula and verified before deployment._

### Plugin ID Reference

| Plugin                 | Plugin ID                                                     |
| ---------------------- | ------------------------------------------------------------- |
| HeliosMessageReceiver  | `bytes4(keccak256("across.message-receiver.helios"))`         |
| OPCrossDomainReceiver  | `bytes4(keccak256("across.message-receiver.op-crossdomain"))` |
| ArbitrumInboxReceiver  | `bytes4(keccak256("across.message-receiver.arbitrum"))`       |
| AdminOnlyReceiver      | `bytes4(keccak256("across.message-receiver.admin-only"))`     |
| CCTPBridgePlugin       | `bytes4(keccak256("across.bridge-plugin.cctp"))`              |
| OFTBridgePlugin        | `bytes4(keccak256("across.bridge-plugin.oft"))`               |
| OPStandardBridgePlugin | `bytes4(keccak256("across.bridge-plugin.op-standard"))`       |
| ArbitrumGatewayPlugin  | `bytes4(keccak256("across.bridge-plugin.arb-gateway"))`       |
