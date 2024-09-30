// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

/**
 * @title ForwarderBase
 * @notice This contract expects to receive messages and tokens from an authorized sender on a previous layer and forwards messages and tokens
 * to contracts on subsequent layers. Messages are intended to originate from the hub pool or other forwarder contracts. The motivating use case
 * for this contract is to aid with sending messages from L1 to an L3, which by definition is a network which does not have a direct connection
 * with L1 but instead must communicate with that L1 via an L2. Each contract that extends the ForwarderBase maintains a mapping of 
 * contracts that exist on networks that are connected to the network that this contract is deployed on. For example, if this contract is deployed on
 * Arbitrum, then there could be a mapping of contracts for each L3 that is connected to Arbitrum and communicates to L1 via Arbitrum. In other words,
 * this contract maintains a mapping of important contracts on the "next layer" and is used to help relay messages from L1 to L3 by sending messages
 * through the next layer. Messages could be forwarded across an indefinite amount of layers by recursively wrapping and sending messages over canonical
 * bridges, only stopping when the following network contains the intended target contract.
 * @custom:security-contact bugs@across.to
 */
abstract contract ForwarderBase is UUPSUpgradeable, AdapterInterface {
    /**
     * @notice Route contains all information needed in order to send a message to the next layer. It describes two possible paths: a message is sent
     * through `adapter` (on this network) to the `forwarder` on the next layer, or a message is sent through `adapter` to the `spokePool`.
     * @dev We need to know three different addresses:
     *   - The address of the adapter to delegatecall, so that we may propagate message and token relays. This contract lives on this layer.
     *   - The address of the next layer's forwarder, so that we can continue the message and token relay chain.
     *   - The address of the next layer's spoke pool, so that we can determine whether the following network contains the target spoke pool.
     * these addresses describe the path a message or token relay must take to arrive at the next layer. A Route only describes the path to arrive
     * a layer closer to to the ultimate target, unless one of the `forwarder` or `spokePool` addresses equal the target contract, in which case
     * the path ends. All Routes must contain an adapter address; however, not all Routes must contain a forwarder or spokePool address. For example,
     * we may send a message to a spoke pool on a network with no corresponding forwarder contract, or we may send a message to a network which contains
     * a forwarder contract but no spoke pool.
     */
    struct Route {
        address adapter;
        address forwarder;
        address spokePool;
    }

    // Address of the contract which can relay messages to the subsequent forwarders/spoke pools and update this proxy contract.
    address public crossDomainAdmin;

    // Map from a destination address to the next token/message bridge route to reach the destination address. The destination address can either be a
    // spoke pool or a forwarder. Destination addresses are used as the key in this mapping because the `target` address is the only information
    // we receive when `relay{Message/Token}` is called on this contract, so we assume that these destination contracts on all the possible next
    // layers have unique addresses. Ideally we could use the destination chain ID as a key for this mapping but we don't have that available where this
    // mapping is accessed in `relay{Message/Token}`
    mapping(address => Route) possibleRoutes;

    // Map which takes as input the destination address and a token address on the current network and outputs the corresponding remote token address, 
    // which is the equivalent of the token address on the destination network.
    mapping(address => mapping(address => address)) destinationChainTokens;

    event TokensForwarded(address indexed target, address indexed baseToken, uint256 amount);
    event MessageForwarded(address indexed target, bytes message);
    event RouteUpdated(address indexed target, Route route);
    event DestinationChainTokensUpdated(
        address indexed target,
        address indexed baseToken,
        address indexed destinationChainToken
    );

    error InvalidL3SpokePool();
    error RelayMessageFailed();
    error RelayTokensFailed(address baseToken);
    // Error which is triggered when there is no adapter set for a given route.
    error UninitializedRoute();
    // Error which is triggered when we attempted send tokens or a message relay to a forwarder which is uninitialized.
    error MalformedRoute();

    /*
     * @dev Cross domain admin permissioning is implemented specifically for each L2 that this contract is deployed on, so this base contract
     * simply prescribes this modifier to protect external functions using that L2's specific admin permissioning logic.
     */
    modifier onlyAdmin() {
        _requireAdminSender();
        _;
    }

    /**
     * @notice Constructs the Forwarder contract.
     * @dev _disableInitializers() restricts anybody from initializing the implementation contract, which if not done,
     * may disrupt the proxy if another EOA were to initialize it.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the forwarder contract.
     */
    function __Forwarder_init() public onlyInitializing {
        __UUPSUpgradeable_init();
    }

    /**
     * @notice Maps a new set of contracts that exist on the network to a destination address.
     * @param _destinationAddress The address on the destination chain that we want to send messages to from this contract.
     * @param _route Contracts available on the destinatio network that we want to send messages to.
     * @dev Each forwarder will not know how many layers it must traverse to arrive at _destinationAddress until it is precisely
     * one layer away. The possibleRoutes mapping lets the forwarder know what path it should take to progess, and then relies on
     * the forwarders on the subsequent layers to derive the next route in sequence.
     */
    function updateRoute(address _destinationAddress, Route memory _route) external onlyAdmin {
        possibleRoutes[_destinationAddress] = _route;
        emit RouteUpdated(_destinationAddress, _route);
    }

    /**
     * @notice Sets a new remote token in the destinationChainTokens mapping.
     * @param _destinationAddress The address to set in the destinationChainTokens mapping. This is to identify the network associated with the
     * destination chain token.
     * @param _baseToken The address of the token which exists on the current network.
     * @param _destinationChainToken The address of the token on the network which is next on the path to _destinationAddress.
     * @dev This mapping also relies on using _destinationAddress to determine the network to bridge to. Consequently, it requires that a new
     * _destinationAddress does not collide with an existing key in the `destinationChainTokens` mapping.
     */
    function updateRemoteToken(
        address _destinationAddress,
        address _baseToken,
        address _destinationChainToken
    ) external onlyAdmin {
        destinationChainTokens[_destinationAddress][_baseToken] = _destinationChainToken;
        emit DestinationChainTokensUpdated(_destinationAddress, _baseToken, _destinationChainToken);
    }

    /**
     * @notice Relays a specified message to a contract on the following layer. If `target` exists on the following layer, then `message` is sent
     * to it. Otherwise, `message` is sent to the next layer's forwarder contract.
     * @param target The address of the spoke pool or forwarder contract that will receive the input message.
     * @param message The data to execute on the target contract.
     * @dev Each forwarder will only know if they are on the layer directly before the layer which contains the `target` contract.
     * If the next layer contains the target, we send `message` cross-chain normally. Otherwise, we wrap `message` into a `relayMessage`
     * call to the next layer's forwarder contract.
     */
    function relayMessage(address target, bytes memory message) external payable override onlyAdmin {
        Route storage nextLayerContracts = possibleRoutes[target];
        if (nextLayerContracts.adapter == address(0)) revert UninitializedRoute();
        bool success;
        // Case 1: We are on the network immediately before our target, so we forward the original message over the canonical messaging bridge.
        if (target == nextLayerContracts.spokePool || target == nextLayerContracts.forwarder) {
            (success, ) = nextLayerContracts.adapter.delegatecall(abi.encodeCall(AdapterInterface.relayMessage, (target, message)));
        } else {
            if (nextLayerContracts.forwarder == address(0)) revert MalformedRoute();
            // Case 2: We are not on the network immediately before our target, so we wrap the message in a `relayMessage` call and forward it
            // to the next forwarder on the path to the target contract.
            bytes memory wrappedMessage = abi.encodeCall(AdapterInterface.relayMessage, (target, message));
            (success, ) = nextLayerContracts.adapter.delegatecall(
                abi.encodeCall(AdapterInterface.relayMessage, (nextLayerContracts.forwarder, wrappedMessage))
            );
        }
        if (!success) revert RelayMessageFailed();
        emit MessageForwarded(target, message);
    }

    /**
     * @notice Relays `amount` of a token to a contract on the following layer. If `target` does not exist on the following layer, then the tokens
     * are sent to the following layer's forwarder contract.
     * @param baseToken This layer's address of the token to send.
     * @param destinationChainToken The next layer's address of the token to send.
     * @param amount The amount of the token to send.
     * @param target The address of the contract that which will *ultimately* receive the tokens. That is, the spoke pool contract address on an
     * arbitrary layer which receives `amount` of a token after all forwards have been completed.
     * @dev The relayTokens function (which must be implemented on a per-chain basis) needs to inductively determine the address of the remote token
     * given a known baseToken. Then, once the correct addresses are obtained, this function may be called to finish the relay of tokens.
     */
    function _relayTokens(
        address baseToken,
        address destinationChainToken,
        uint256 amount,
        address target
    ) internal {
        Route storage nextLayerContracts = possibleRoutes[target];
        if (nextLayerContracts.adapter == address(0)) revert UninitializedRoute();
        bool success;
        // Case 1: We are immediately before the target spoke pool, so we send the tokens to the spoke pool
        // and do NOT follow it up with a message.
        if (target == nextLayerContracts.spokePool) {
            (success, ) = nextLayerContracts.adapter.delegatecall(
                abi.encodeCall(AdapterInterface.relayTokens, (baseToken, destinationChainToken, amount, target))
            );
            if (!success) revert RelayTokensFailed(baseToken);
        } else {
            // Case 2: We are not immediately before the target spoke pool, so we send the tokens to the next
            // forwarder and accompany it with a message containing information about its intended destination.

            if (nextLayerContracts.forwarder == address(0)) revert MalformedRoute();
            // Send tokens to the forwarder.
            (success, ) = nextLayerContracts.adapter.delegatecall(
                abi.encodeCall(
                    AdapterInterface.relayTokens,
                    (baseToken, destinationChainToken, amount, nextLayerContracts.forwarder)
                )
            );
            if (!success) revert RelayTokensFailed(baseToken);

            // Send a follow-up message to the forwarder which tells it to continue bridging.
            bytes memory message = abi.encodeCall(
                AdapterInterface.relayTokens,
                (baseToken, destinationChainToken, amount, target)
            );
            (success, ) = nextLayerContracts.adapter.delegatecall(
                abi.encodeCall(AdapterInterface.relayMessage, (nextLayerContracts.forwarder, message))
            );
            if (!success) revert RelayMessageFailed();
        }
        emit TokensForwarded(target, baseToken, amount);
    }

    // Function to be overridden in order to authenticate that messages sent to this contract originated
    // from the expected account.
    function _requireAdminSender() internal virtual;

    // We also want to restrict who can upgrade this contract. The same admin that can relay messages through this
    // contract can upgrade this contract.
    function _authorizeUpgrade(address) internal virtual override onlyAdmin {}
}
