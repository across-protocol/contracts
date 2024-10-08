// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";
import { ForwarderInterface } from "./interfaces/ForwarderInterface.sol";
import { HubPoolInterface } from "../interfaces/HubPoolInterface.sol";

/**
 * @notice Contract containing logic to send messages from L1 to "L3" networks that do not have direct connections
 * with L1. L3's are defined as networks that connect to L1 indirectly via L2, and this contract sends
 * messages to those L3's by rerouting them via those L2's. This contract is called a "Router" because it uses
 * (i.e. delegatecall's) existing L2 adapter logic to send a message first from L1 to L2 and then from L2 to L3.
 * @dev Due to the constraints of the `SetCrossChainContracts` event as outlined in UMIP-157 and how the HubPool
 * delegatecalls adapters like this one, all messages relayed through this
 * adapter have target addresses on the L3's. However, these target addresses do not exist on L2 where all messages are
 * rerouted through. Therefore, this contract is designed to be used in tandem with "L2 Forwarder Adapters" which help
 * get the messages from L1 to L3 via L2's.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Router_Adapter is AdapterInterface {
    // Adapter designed to relay messages from L1 to L2 addresses and delegatecalled by this contract to reroute
    // messages to L3 via the L2_TARGET.
    address public immutable L1_ADAPTER;
    // L2_TARGET is a "Forwarder" contract that will help relay messages from L1 to L3. Messages are "rerouted" through
    // the L2_TARGET.
    address public immutable L2_TARGET;
    // L2_CHAIN_ID is the chain ID of the network which is "in between" the L1 and L3. This network will contain the forwarder.
    uint256 public immutable L2_CHAIN_ID;
    // L3_CHAIN_ID is the chain ID of the network which contains the target spoke pool. This chain id is passed to the
    // forwarder contract so that it may determine the correct L2-L3 bridge to use to arrive at L3.
    uint256 public immutable L3_CHAIN_ID;
    // Interface of the Hub Pool. Used to query state related to L1-L2 token mappings.
    HubPoolInterface public immutable HUB_POOL;

    error RelayMessageFailed();
    error RelayTokensFailed(address l1Token);
    error L2RouteNotWhitelisted(address l1Token);

    /**
     * @notice Constructs new Adapter. This contract will re-route messages destined for an L3 to L2_TARGET via the L1_ADAPTER contract.
     * @param _l1Adapter Address of the adapter contract on mainnet which implements message transfers
     * and token relays to the L2 where _l2Target is deployed.
     * @param _l2Target Address of the L2 contract which receives the token and message relays in order to forward them to an L3.
     * @param _l2ChainId Chain ID of the network which contains the forwarder. It is the network which is intermediate in message
     * transmission from L1 to L3.
     * @param _l3ChainId Chain ID of the network which contains the spoke pool which corresponds to this adapter instance.
     * @param _hubPool Address of the hub pool deployed on L1.
     */
    constructor(
        address _l1Adapter,
        address _l2Target,
        uint256 _l2ChainId,
        uint256 _l3ChainId,
        HubPoolInterface _hubPool
    ) {
        L1_ADAPTER = _l1Adapter;
        L2_TARGET = _l2Target;
        L2_CHAIN_ID = _l2ChainId;
        L3_CHAIN_ID = _l3ChainId;
        HUB_POOL = _hubPool;
    }

    /**
     * @notice Send cross-chain message to a target on L2 which will forward messages to the intended remote target on an L3.
     * @param target Address of the remote contract which receives `message` after it has been forwarded by all intermediate
     * contracts.
     * @param message Data to send to `target`.
     * @dev The message passed into this function is wrapped into a `relayMessage` function call, which is then passed
     * to L2. The `L2_TARGET` contract implements AdapterInterface, so upon arrival on L2, the arguments to the L2 contract's
     * `relayMessage` call will be these `target` and `message` values. From there, the forwarder derives the next appropriate
     * method to send `message` to the following layers and ultimately to the target on L3.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        bytes memory wrappedMessage = abi.encodeCall(ForwarderInterface.relayMessage, (target, L3_CHAIN_ID, message));
        (bool success, ) = L1_ADAPTER.delegatecall(
            abi.encodeCall(AdapterInterface.relayMessage, (L2_TARGET, wrappedMessage))
        );
        if (!success) revert RelayMessageFailed();
    }

    /**
     * @notice Bridge tokens to a target on L2 and follow up the token bridge with a call to continue bridging the sent tokens.
     * @param l1Token L1 token to deposit.
     * @param l3Token L3 token to receive.
     * @param amount Amount of L1 tokens to deposit and L3 tokens to receive.
     * @param target The address of the contract which should ultimately receive `amount` of `l3Token`.
     * @dev When sending tokens, we follow-up with a message describing the amount of tokens we wish to continue bridging.
     * This allows forwarders to know how much of some token to allocate to a certain target.
     */
    function relayTokens(
        address l1Token,
        address l3Token,
        uint256 amount,
        address target
    ) external payable override {
        // Fetch the address of the L2 token, as defined in the Hub Pool. This is to complete a proper token bridge from L1 to L2.
        address l2Token = HUB_POOL.poolRebalanceRoute(L2_CHAIN_ID, l1Token);
        // If l2Token is the zero address, then this means that the L2 token is not enabled as a pool rebalance route. This is similar
        // to the check in the hub pool contract found here: https://github.com/across-protocol/contracts/blob/a2afefecba57177a62be35be092516d0c106097e/contracts/HubPool.sol#L890
        if (l2Token == address(0)) revert L2RouteNotWhitelisted(l1Token);

        // Relay tokens to the forwarder.
        (bool success, ) = L1_ADAPTER.delegatecall(
            abi.encodeCall(AdapterInterface.relayTokens, (l1Token, l2Token, amount, L2_TARGET))
        );
        if (!success) revert RelayTokensFailed(l1Token);

        // Follow-up token relay with a message to continue the token relay on L2.
        bytes memory message = abi.encodeCall(
            ForwarderInterface.relayTokens,
            (l2Token, l3Token, amount, L3_CHAIN_ID, target)
        );
        (success, ) = L1_ADAPTER.delegatecall(abi.encodeCall(AdapterInterface.relayMessage, (L2_TARGET, message)));
        if (!success) revert RelayMessageFailed();
    }
}
