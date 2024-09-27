// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

/**
 * @title ForwarderBase
 * @notice This contract expects to receive messages and tokens from an authorized sender on a previous layer and forwards messages and tokens
 * to contracts on subsequent layers. Messages are intended to originate from the hub pool or other forwarder contracts. It rejects messages which
 * do not originate from the cross domain admin, which should be set to these contracts, depending on the sender on the previous layer.
 * @dev Base contract designed to be deployed on a layer > L1 to re-route messages to a further layer. If a message is sent to this contract which
 * came from the cross domain admin, then it is routed to the next layer via the canonical messaging bridge. Tokens sent from L1 are accompanied by a
 * message directing this contract on the next steps of the token relay.
 * @custom:security-contact bugs@across.to
 */
abstract contract ForwarderBase is UUPSUpgradeable, AdapterInterface {
    /**
     * @notice Struct containing all information needed in order to send a message to the next layer.
     * @dev We need to know three different addresses:
     *   - The address of the adapter to delegatecall, so that we may propagate message and token relays.
     *   - The address of the next layer's forwarder, so that we can identify the intended recipient of message and token relays.
     *   - The address of the next layer's spoke pool, so that we can determine whether the next chain contains the target spoke pool.
     */
    struct RouteIndex {
        address adapter;
        address forwarder;
        address spokePool;
    }

    // L1 address of the contract which can relay messages to the l3SpokePool contract and update this proxy contract.
    address public crossDomainAdmin;
    // Map from a destination address to the next token/message bridge route to reach the destination address. The destination
    // address can either be a spoke pool or a forwarder. This mapping requires that no destination addresses (i.e. spoke pool or
    // forwarder addresses) collide.
    mapping(address => RouteIndex) availableRoutes;
    // Map which takes inputs the destination address and a token address on the current network and outputs the corresponding remote token address.
    mapping(address => mapping(address => address)) remoteTokens;

    event TokensForwarded(address indexed target, address indexed baseToken, uint256 amount);
    event MessageForwarded(address indexed target, bytes message);
    event SetXDomainAdmin(address indexed crossDomainAdmin);
    event RouteUpdated(address indexed target, RouteIndex route);
    event RemoteTokensUpdated(address indexed target, address indexed baseToken, address indexed remoteToken);

    error InvalidCrossDomainAdmin();
    error InvalidL3SpokePool();
    error RelayMessageFailed();
    error RelayTokensFailed(address baseToken);

    /*
     * @dev All functions with this modifier must revert if msg.sender != crossDomainAdmin. Each L2 may have
     * unique aliasing logic, so it is up to the chain-specific forwarder contract to verify that the sender is valid.
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
     * @param _crossDomainAdmin L1 address of the contract which can send root bundles/messages to this forwarder contract.
     * In practice, this is the hub pool.
     */
    function __Forwarder_init(address _crossDomainAdmin) public onlyInitializing {
        __UUPSUpgradeable_init();
        _setCrossDomainAdmin(_crossDomainAdmin);
    }

    /**
     * @notice Sets a new cross domain admin for this contract.
     * @param _newCrossDomainAdmin L1 address of the new cross domain admin.
     */
    function setCrossDomainAdmin(address _newCrossDomainAdmin) external onlyAdmin {
        _setCrossDomainAdmin(_newCrossDomainAdmin);
    }

    /**
     * @notice Sets a new RouteIndex to a specified address.
     * @param _destinationAddress The address to set in the availableRoutes mapping.
     * @param _routeIndex RouteIndex struct containing the next immediate path to reach the _destination address.
     * @dev Each forwarder will not know how many layers it must traverse to arrive at _destinationAddress until it is precisely
     * one layer away. The availableRoutes mapping lets the forwarder know what path it should take to progess, and then relies on
     * the forwarders on the subsequent layers to derive the next route in sequence.
     */
    function updateRoute(address _destinationAddress, RouteIndex memory _routeIndex) external onlyAdmin {
        availableRoutes[_destinationAddress] = _routeIndex;
        emit RouteUpdated(_destinationAddress, _routeIndex);
    }

    /**
     * @notice Sets a new remote token in the remoteTokens mapping.
     * @param _destinationAddress The address to set in the remoteTokens mapping. This is to identify the network associated with the
     * remote token.
     * @param _baseToken The address of the token which exists on the current network.
     * @param _remoteToken The address of the token on the network which is next on the path to _destinationAddress.
     * @dev This mapping also relies on using _destinationAddress to determine the network to bridge to.
     */
    function updateRemoteToken(
        address _destinationAddress,
        address _baseToken,
        address _remoteToken
    ) external onlyAdmin {
        remoteTokens[_destinationAddress][_baseToken] = _remoteToken;
        emit RemoteTokensUpdated(_destinationAddress, _baseToken, _remoteToken);
    }

    /**
     * @notice Relays a specified message to a target on an arbitrary layer.
     * @param target The address of the contract that will receive the input message.
     * @param message The data to execute on the contract.
     * @dev Each forwarder will only know if they are on the layer directly before the layer which contains the `target` contract.
     * If the next layer contains the target, we send `message` cross-chain normally. Otherwise, we wrap `message` into a `relayMessage`
     * call to the next layer's forwarder contract.
     */
    function relayMessage(address target, bytes memory message) external payable override onlyAdmin {
        RouteIndex storage route = availableRoutes[target];
        bool success;
        // Case 1: We are on the network immediately before our target, so we forward the original message over the canonical messaging bridge.
        if (target == route.spokePool || target == route.forwarder) {
            (success, ) = route.adapter.delegatecall(abi.encodeCall(AdapterInterface.relayMessage, (target, message)));
        } else {
            // Case 2: We are not on the network immediately before our target, so we wrap the message in a `relayMessage` call and forward it
            // to the next forwarder on the path to the target contract.
            bytes memory wrappedMessage = abi.encodeCall(AdapterInterface.relayMessage, (target, message));
            (success, ) = route.adapter.delegatecall(
                abi.encodeCall(AdapterInterface.relayMessage, (route.forwarder, wrappedMessage))
            );
        }
        if (!success) revert RelayMessageFailed();
        emit MessageForwarded(target, message);
    }

    /**
     * @notice Relays `amount` of a token to `target` over an arbitrary number of layers.
     * @param baseToken This layer's address of the token to send.
     * @param remoteToken The next layer's address of the token to send.
     * @param amount The amount of the token to send.
     * @param target The address of the contract that will receive the tokens.
     * @dev The relayTokens function (which must be implemented on a per-chain basis) needs to inductively determine the address of the
     * remote token given a known baseToken. Then, once the correct addresses are obtained, this function may be called to finish the
     * relay of tokens.
     */
    function _relayTokens(
        address baseToken,
        address remoteToken,
        uint256 amount,
        address target
    ) internal {
        RouteIndex storage route = availableRoutes[target];
        bool success;
        // Case 1: We are immediately before the target spoke pool, so we send the tokens to the spoke pool
        // and do NOT follow it up with a message.
        if (target == route.spokePool) {
            (success, ) = route.adapter.delegatecall(
                abi.encodeCall(AdapterInterface.relayTokens, (baseToken, remoteToken, amount, target))
            );
            if (!success) revert RelayTokensFailed(baseToken);
        } else {
            // Case 2: We are not immediately before the target spoke pool, so we send the tokens to the next
            // forwarder and accompany it with a message containing information about its intended destination.

            // Send tokens to the forwarder.
            (success, ) = route.adapter.delegatecall(
                abi.encodeCall(AdapterInterface.relayTokens, (baseToken, remoteToken, amount, route.forwarder))
            );
            if (!success) revert RelayTokensFailed(baseToken);

            // Send a follow-up message to the forwarder which tells it to continue bridging.
            bytes memory message = abi.encodeCall(
                AdapterInterface.relayTokens,
                (baseToken, remoteToken, amount, target)
            );
            (success, ) = route.adapter.delegatecall(
                abi.encodeCall(AdapterInterface.relayMessage, (route.forwarder, message))
            );
            if (!success) revert RelayMessageFailed();
        }
        emit TokensForwarded(target, baseToken, amount);
    }

    // Function to be overridden to accomodate for each L2's unique method of address aliasing.
    function _requireAdminSender() internal virtual;

    // Use the same access control logic implemented in the forwarders to authorize an upgrade.
    function _authorizeUpgrade(address) internal virtual override onlyAdmin {}

    function _setCrossDomainAdmin(address _newCrossDomainAdmin) internal {
        if (_newCrossDomainAdmin == address(0)) revert InvalidCrossDomainAdmin();
        crossDomainAdmin = _newCrossDomainAdmin;
        emit SetXDomainAdmin(_newCrossDomainAdmin);
    }
}
