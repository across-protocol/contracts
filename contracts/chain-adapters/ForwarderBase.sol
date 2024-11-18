// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { ForwarderInterface } from "./interfaces/ForwarderInterface.sol";
import { AdapterInterface } from "./interfaces/AdapterInterface.sol";
import { MultiCaller } from "@uma/core/contracts/common/implementation/MultiCaller.sol";
import { WETH9Interface } from "../external/interfaces/WETH9Interface.sol";

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
abstract contract ForwarderBase is UUPSUpgradeable, ForwarderInterface, MultiCaller, ReentrancyGuardUpgradeable {
    // Address of the wrapped native token contract on this L2.
    WETH9Interface public immutable WRAPPED_NATIVE_TOKEN;
    // Address that can relay messages using this contract and also upgrade this contract.
    address public crossDomainAdmin;

    // Map from a destination chain ID to the address of an adapter contract which interfaces with the L2-L3 bridge. The destination chain ID corresponds to
    // the network ID of an L3. These chain IDs are used as the key in this mapping because network IDs are enforced to be unique. Since we require the chain
    // ID to be sent along with a message or token relay, ForwarderInterface's relay functions include an extra field, `destinationChainId`, when compared to the
    // relay functions of `AdapterInterface`.
    mapping(uint256 => address) public chainAdapters;

    // An array of which contains all token relays sent to this forwarder. A token relay is only stored here if it is received from the L1 cross domain admin.
    // Each TokenRelay element contains a yes/no value describing whether or not the token relay has been executed. TokenRelays can only ever be executed once,
    // but anybody can execute a stored TokenRelay in the array.
    TokenRelay[] public tokenRelays;

    event ChainAdaptersUpdated(uint256 indexed destinationChainId, address l2Adapter);
    event SetXDomainAdmin(address indexed crossDomainAdmin);

    error InvalidCrossDomainAdmin();
    error InvalidChainAdapter();
    error InvalidTokenRelayId();
    // Error which is triggered when there is no adapter set in the `chainAdapters` mapping.
    error UninitializedChainAdapter();
    // Error which is triggered when the contract attempts to wrap a native token for an amount greater than
    // its balance.
    error InsufficientNativeTokenBalance();

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
     * @param _wrappedNativeToken Address of the wrapped native token contract on the L2.
     * @dev _disableInitializers() restricts anybody from initializing the implementation contract, which if not done,
     * may disrupt the proxy if another EOA were to initialize it.
     */
    constructor(WETH9Interface _wrappedNativeToken) {
        WRAPPED_NATIVE_TOKEN = _wrappedNativeToken;
        _disableInitializers();
    }

    /**
     * @notice Receives the native token from external sources.
     * @dev Forwarders need a receive function so that it may accept the native token incoming from L1-L2 bridges.
     */
    receive() external payable {}

    /**
     * @notice Initializes the forwarder contract.
     * @param _crossDomainAdmin L1 address of the contract which can send root bundles/messages to this forwarder contract.
     */
    function __Forwarder_init(address _crossDomainAdmin) public onlyInitializing {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _setCrossDomainAdmin(_crossDomainAdmin);
    }

    /**
     * @notice Sets a new cross domain admin for this contract.
     * @param _newCrossDomainAdmin L1 address of the new cross domain admin.
     * @dev Before calling this function, you must ensure that there are no message or token relays currently being sent over the L1-L2
     * bridge. This is to prevent these messages from getting permanently stuck, since otherwise receipt of these messages will always revert,
     * as the L1 sender is the old cross-domain admin.
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
    function updateAdapter(uint256 _destinationChainId, address _l2Adapter) external onlyAdmin {
        if (_l2Adapter == address(0)) revert InvalidChainAdapter();
        _updateAdapter(_destinationChainId, _l2Adapter);
    }

    /**
     * @notice Removes this contract's set adapter for the specified chain ID.
     * @param _destinationChainId The chain ID of the target network.
     */
    function removeAdapter(uint256 _destinationChainId) external onlyAdmin {
        _updateAdapter(_destinationChainId, address(0));
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
        if (adapter == address(0)) revert UninitializedChainAdapter();

        // The forwarder assumes that `target` exists on the following network.
        (bool success, ) = adapter.delegatecall(abi.encodeCall(AdapterInterface.relayMessage, (target, message)));
        if (!success) revert RelayMessageFailed();
        emit MessageForwarded(target, destinationChainId, message);
    }

    /**
     * @notice Stores information about sending `amount` of a token to a target on L3. Importantly, this contract assumes that `target` exists on L3.
     * @param l2Token This layer's address of the token to send.
     * @param l3Token The next layer's address of the token to send.
     * @param amount The amount of the token to send.
     * @param destinationChainId The chain ID of the network which contains `target`.
     * @param to The address of the contract that which will *ultimately* receive the tokens. For most cases, this is the spoke pool contract on L3.
     * @dev While `relayMessage` also assumes that `target` is correct, this function has the potential of deleting funds if `target` is incorrectly set.
     * This should be guarded by the logic of the Hub Pool on L1, since the Hub Pool will always set `target` to the L3 spoke pool per UMIP-157.
     * @dev This function does not perform the bridging action. Instead, it receives information from the hub pool on L1 and saves it to state, so that it
     * may be executed in the future by any EOA.
     */
    function relayTokens(
        address l2Token,
        address l3Token,
        uint256 amount,
        uint256 destinationChainId,
        address to
    ) external payable override onlyAdmin {
        uint32 tokenRelayId = uint32(tokenRelays.length);
        // Create a TokenRelay struct with all the information provided.
        TokenRelay memory tokenRelay = TokenRelay({
            l2Token: l2Token,
            l3Token: l3Token,
            to: to,
            amount: amount,
            destinationChainId: destinationChainId,
            executed: false
        });
        // Save the token relay to state.
        tokenRelays.push(tokenRelay);
        emit ReceivedTokenRelay(tokenRelayId, tokenRelay);
    }

    /**
     * @notice Sends a stored TokenRelay to L3.
     * @param tokenRelayId Index of the relay to send in the `tokenRelays` array.
     */
    function executeRelayTokens(uint32 tokenRelayId) external payable nonReentrant {
        if (tokenRelayId >= tokenRelays.length) revert InvalidTokenRelayId();
        TokenRelay storage tokenRelay = tokenRelays[tokenRelayId];
        if (tokenRelay.executed) revert TokenRelayExecuted();

        address adapter = chainAdapters[tokenRelay.destinationChainId];
        if (adapter == address(0)) revert UninitializedChainAdapter();
        if (tokenRelay.l2Token == address(WRAPPED_NATIVE_TOKEN)) {
            // Only wrap the minimum required amount of the native token.
            uint256 wrappedNativeTokenBalance = WRAPPED_NATIVE_TOKEN.balanceOf(address(this));
            if (wrappedNativeTokenBalance < tokenRelay.amount)
                _wrapNativeToken(tokenRelay.amount - wrappedNativeTokenBalance);
        }

        tokenRelay.executed = true;
        (bool success, ) = adapter.delegatecall(
            abi.encodeCall(
                AdapterInterface.relayTokens,
                (tokenRelay.l2Token, tokenRelay.l3Token, tokenRelay.amount, tokenRelay.to)
            )
        );
        if (!success) revert RelayTokensFailed(tokenRelay.l2Token);

        emit ExecutedTokenRelay(tokenRelayId);
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

    function _updateAdapter(uint256 _destinationChainId, address _l2Adapter) internal {
        chainAdapters[_destinationChainId] = _l2Adapter;
        emit ChainAdaptersUpdated(_destinationChainId, _l2Adapter);
    }

    /*
     * @notice Wraps the specified amount of the network's native token.
     */
    function _wrapNativeToken(uint256 wrapAmount) internal {
        if (address(this).balance < wrapAmount) revert InsufficientNativeTokenBalance();
        WRAPPED_NATIVE_TOKEN.deposit{ value: wrapAmount }();
    }

    // Reserve storage slots for future versions of this base contract to add state variables without
    // affecting the storage layout of child contracts. Decrement the size of __gap whenever state variables
    // are added. This is at bottom of contract to make sure it's always at the end of storage.
    uint256[1000] private __gap;
}
