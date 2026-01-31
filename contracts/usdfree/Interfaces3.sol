// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/*
Key design principles:
1. The dst payload shape is ONLY known to the bridge adapter - src chain logic is agnostic
2. Add-on requirements (submitter, token from auction) are attached at bridge time, not by user
3. Recursion: userActions can end with a bridge adapter call, which embeds another order

Flow:
- User signs Order with userActions
- userActions can end with IBridgeAdapter.bridge(...) call
- Bridge adapter receives: (a) dst order, (b) add-on requirements from auction
- On dst, handler unpacks payload, merges requirements, executes
*/

// ============ Core Order Structures ============

// Base order that can execute on any chain
// Note: no submitterRequirement here - that's handled separately by Gateway/auction
struct OrderCore {
    bytes staticRequirements; // version-prefixed requirements (token, deadline, etc.)
    bytes userActions; // weiroll/multicall instructions - can end with bridge adapter call
}

// Full order with salt for uniqueness (what user signs on src)
struct Order {
    bytes32 salt;
    bytes submitterRequirement; // checked on src by Gateway
    OrderCore core;
}

// ============ Requirements ============

// Add-on requirements that can be attached during bridging
// These come from the auction system, not the user
struct AddOnRequirements {
    bytes submitterRequirement; // dst chain submitter (from auction)
    bytes tokenRequirement; // extra token the submitter must provide (from auction)
    // Extensible: future versions can add more fields
}

// ============ Bridge Adapter Interface ============

// Bridge adapters are the ONLY components that know the dst payload shape.
// They're called as the final action in userActions when bridging is needed.
interface IBridgeAdapter {
    /// @notice Send order to destination chain
    /// @param dstChainId Target chain identifier
    /// @param dstOrder The OrderCore to execute on dst (can recursively contain another bridge call)
    /// @param addOnReqs Requirements to attach (submitter, token from auction)
    /// @param bridgeData Adapter-specific data (e.g., bridge fees, receiver address)
    function bridge(
        uint256 dstChainId,
        OrderCore calldata dstOrder,
        AddOnRequirements calldata addOnReqs,
        bytes calldata bridgeData
    ) external payable;

    /// @notice Quote bridge fees
    function quoteBridge(
        uint256 dstChainId,
        OrderCore calldata dstOrder,
        AddOnRequirements calldata addOnReqs,
        bytes calldata bridgeData
    ) external view returns (uint256 fee);
}

// ============ Destination Handler Interface ============

// What the bridge adapter sends cross-chain (adapter encodes this)
// Each adapter can have its own payload format, but must decode to this for execution
struct DstPayload {
    OrderCore order;
    AddOnRequirements addOnReqs;
}

// Destination-side handler that receives bridged orders
interface IDstHandler {
    /// @notice Called by bridge receiver (e.g., OFT handler, CCTP handler)
    /// @param payload Encoded DstPayload
    /// @param bridgedToken Token that arrived via bridge
    /// @param bridgedAmount Amount that arrived
    function handleBridgedOrder(bytes calldata payload, address bridgedToken, uint256 bridgedAmount) external;
}

// ============ Executor Interface ============

interface IOrderExecutor {
    /// @notice Execute an order with merged requirements
    /// @param baseRequirements User's original staticRequirements
    /// @param addOnReqs Additional requirements from auction/bridging
    /// @param userActions User's actions to execute
    /// @param submitterActions Submitter's pre-actions (swaps, etc.)
    function execute(
        bytes calldata baseRequirements,
        AddOnRequirements calldata addOnReqs,
        bytes calldata userActions,
        bytes calldata submitterActions
    ) external payable;
}

// ============ Example Concrete Adapter ============

/// @notice Example: Adapter for a generic messaging bridge
abstract contract BaseBridgeAdapter is IBridgeAdapter {
    function bridge(
        uint256 dstChainId,
        OrderCore calldata dstOrder,
        AddOnRequirements calldata addOnReqs,
        bytes calldata bridgeData
    ) external payable virtual override {
        // 1. Encode payload for dst
        bytes memory payload = abi.encode(DstPayload({ order: dstOrder, addOnReqs: addOnReqs }));

        // 2. Call underlying bridge with payload
        _sendMessage(dstChainId, payload, bridgeData);
    }

    function _sendMessage(uint256 dstChainId, bytes memory payload, bytes calldata bridgeData) internal virtual;
}

/*
============ RECURSION EXAMPLE ============

User wants: ETH (Mainnet) -> USDC (Arbitrum) -> final action on Optimism

1. User signs Order on Mainnet:
   - userActions: [swap ETH->USDC, call ArbBridgeAdapter.bridge(arbOrder, ...)]

2. arbOrder contains:
   - userActions: [swap on Arb, call OptBridgeAdapter.bridge(optOrder, ...)]

3. optOrder contains:
   - userActions: [final actions on Optimism]

Each bridge() call can attach AddOnRequirements from the auction for that hop.

============ ADD-ON REQUIREMENTS FLOW ============

Auction determines:
- Src submitter: checked by OrderGateway
- Dst submitter: attached via AddOnRequirements when calling bridge()
- Extra token requirement: also in AddOnRequirements

On dst, executor checks BOTH:
- order.staticRequirements (user-defined)
- addOnReqs.submitterRequirement (auction-defined)
- addOnReqs.tokenRequirement (auction-defined)

This separation means:
- User defines their base requirements
- Auction can layer on additional requirements without user re-signing
*/
