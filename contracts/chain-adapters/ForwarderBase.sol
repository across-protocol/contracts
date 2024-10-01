// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ForwarderInterface } from "./interfaces/ForwarderInterface.sol";
import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

/**
 * @title ForwarderBase
 * @notice This contract expects to receive messages and tokens from an authorized sender on L1 and forwards messages and tokens to spoke pool contracts on
 * L3. Messages are intended to originate from the hub pool. The motivating use case for this contract is to aid with sending messages from L1 to an L3, which
 * by definition is a network which does not have a direct connection with L1 but instead must communicate with that L1 via an L2. Each contract that extends
 * the ForwarderBase maintains a mapping of chain IDs to a bridge adapter addresses. For example, if this contract is deployed on Arbitrum, then this mapping
 * would send L3 chain IDs which roll up to Arbitrum to an adapter contract address deployed on Arbitrum which directly interfaces with the L3 token/message
 * bridge. In other words, this contract maintains a mapping of important contracts which helps transmit messages to the "next layer".
 * @custom:security-contact bugs@across.to
 */
abstract contract ForwarderBase is UUPSUpgradeable, ForwarderInterface {
    // Address that can relay messages using this contract and also upgrade this contract.
    address public crossDomainAdmin;

    // Map from a destination chain ID to the address of an adapter contract which interfaces with the L2-L3 bridge. The destination chain ID corresponds to
    // the network ID of an L3. These chain IDs are used as the key in this mapping because network IDs are enforced to be unique. Since we require the chain
    // ID to be sent along with a message or token relay, ForwarderInterface's relay functions include an extra field, `destinationChainId`, when compared to the
    // relay functions of `AdapterInterface`.
    mapping(uint256 => address) chainAdapters;

    event ChainAdaptersUpdated(uint256 indexed destinationChainId, address l2Adapter);
    event SetXDomainAdmin(address indexed crossDomainAdmin);
    event DestinationChainTokensUpdated(
        address indexed target,
        address indexed baseToken,
        address indexed destinationChainToken
    );

    error InvalidCrossDomainAdmin();
    error RelayMessageFailed();
    error RelayTokensFailed(address baseToken);
    // Error which is triggered when there is no adapter set in the `chainAdapters` mapping.
    error UninitializedRoute();

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
     * @param _crossDomainAdmin L1 address of the contract which can send root bundles/messages to this forwarder contract.
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
     * @notice Maps a new destination chain ID to an adapter contract which facilitates bridging to that chain.
     * @param _destinationChainId The chain ID of the target network.
     * @param _l2Adapter Contract address of the adapter which interfaces with the L2-L3 bridge.
     * @dev Actual bridging logic is delegated to the adapter contract so that the forwarder can function irrespective of the "flavor" of
     * L3 (e.g. ArbitrumOrbit, OpStack, etc.).
     */
    function updateRoute(uint256 _destinationChainId, address _l2Adapter) external onlyAdmin {
        chainAdapters[_destinationChainId] = _l2Adapter;
        emit ChainAdaptersUpdated(_destinationChainId, _l2Adapter);
    }

    /**
     * @notice Relays a specified message to a contract on L3. This contract assumes that `target` exists on the L3 and can properly
     * receive the function being called.
     * @param target The address of the spoke pool contract that will receive the input message.
     * @param destinationChainId The chain ID of the network which contains `target`.
     * @param message The data to execute on the target contract.
     */
    function relayMessage(
        address target,
        uint256 destinationChainId,
        bytes memory message
    ) external payable override onlyAdmin {
        address adapter = chainAdapters[destinationChainId];
        if (adapter == address(0)) revert UninitializedRoute();

        // The forwarder assumes that `target` exists on the following network.
        (bool success, ) = adapter.delegatecall(abi.encodeCall(AdapterInterface.relayMessage, (target, message)));
        if (!success) revert RelayMessageFailed();
        emit MessageForwarded(target, destinationChainId, message);
    }

    /**
     * @notice Relays `amount` of a token to a contract on L3. Importantly, this contract assumes that `target` exists on L3.
     * @param baseToken This layer's address of the token to send.
     * @param destinationChainToken The next layer's address of the token to send.
     * @param amount The amount of the token to send.
     * @param destinationChainId The chain ID of the network which contains `target`.
     * @param target The address of the contract that which will *ultimately* receive the tokens. For most cases, this is the spoke pool contract on L3.
     * @dev While `relayMessage` also assumes that `target` is correct, this function has the potential of deleting funds if `target` is incorrectly set.
     * This should be guarded by the logic of the Hub Pool on L1, since the Hub Pool will always set `target` to the L3 spoke pool per UMIP-157.
     */
    function relayTokens(
        address baseToken,
        address destinationChainToken,
        uint256 amount,
        uint256 destinationChainId,
        address target
    ) external payable override onlyAdmin {
        address adapter = chainAdapters[destinationChainId];
        if (adapter == address(0)) revert UninitializedRoute();
        (bool success, ) = adapter.delegatecall(
            abi.encodeCall(AdapterInterface.relayTokens, (baseToken, destinationChainToken, amount, target))
        );
        if (!success) revert RelayTokensFailed(baseToken);
        emit TokensForwarded(baseToken, destinationChainToken, amount, destinationChainId, target);
    }

    // Function to be overridden in order to authenticate that messages sent to this contract originated
    // from the expected account.
    function _requireAdminSender() internal virtual;

    // We also want to restrict who can upgrade this contract. The same admin that can relay messages through this
    // contract can upgrade this contract.
    function _authorizeUpgrade(address) internal virtual override onlyAdmin {}

    function _setCrossDomainAdmin(address _newCrossDomainAdmin) internal {
        if (_newCrossDomainAdmin == address(0)) revert InvalidCrossDomainAdmin();
        crossDomainAdmin = _newCrossDomainAdmin;
        emit SetXDomainAdmin(_newCrossDomainAdmin);
    }

    // Reserve storage slots for future versions of this base contract to add state variables without
    // affecting the storage layout of child contracts. Decrement the size of __gap whenever state variables
    // are added. This is at bottom of contract to make sure it's always at the end of storage.
    uint256[1000] private __gap;
}
