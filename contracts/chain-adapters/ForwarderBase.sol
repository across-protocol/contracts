// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title ForwarderBase
 * @notice This contract expects to receive messages and tokens from the Hub Pool on L1. It rejects messages which do not originate
 * from the hub pool.
 * @notice Base contract deployed some network between L1 and the network housing a spoke pool contract. If a message is sent
 * to this contract which came from the cross domain admin, then it is routed to the next network via the canonical messaging
 * bridge (which may be done automatically by the network's finalization infrastructure). Tokens sent from L1 are stored temporarily
 * on this contract. Any EOA can initiate a bridge of these tokens to the target `l3SpokePool`.
 * @custom:security-contact bugs@across.to
 */
abstract contract ForwarderBase is UUPSUpgradeable {
    // L3 address of the recipient of L1 messages and tokens.
    address public l3SpokePool;

    // L1 address of the contract which can relay messages to the l3SpokePool contract and update this proxy contract.
    address public crossDomainAdmin;

    event TokensForwarded(address indexed l2Token, uint256 amount);
    event MessageForwarded(address indexed target, bytes message);
    event SetXDomainAdmin(address indexed crossDomainAdmin);
    event SetL3SpokePool(address indexed l3SpokePool);

    error InvalidCrossDomainAdmin();
    error InvalidL3SpokePool();

    /*
     * @dev All functions with this modifier must revert if msg.sender != crossDomainAdmin. Each L2 may have
     * unique aliasing logic, so it is up to the chain-specific forwarder contract to verify that the sender is valid.
     */
    modifier onlyAdmin() {
        _requireAdminSender();
        _;
    }

    /**
     @notice Constructs the Forwarder contract.
     @dev _disableInitializers() restricts anybody from initializing the implementation contract, which if not done, 
     * may disrupt the proxy if another EOA were to initialize it.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the forwarder contract.
     * @param _l3SpokePool L3 address of the contract which will receive messages and tokens which are temporarily
     * stored in this contract on L2.
     * @param _crossDomainAdmin L1 address of the contract which can send root bundles/messages to this forwarder contract.
     * In practice, this is the hub pool.
     */
    function __Forwarder_init(address _l3SpokePool, address _crossDomainAdmin) public onlyInitializing {
        __UUPSUpgradeable_init();
        _setL3SpokePool(_l3SpokePool);
        _setCrossDomainAdmin(_crossDomainAdmin);
    }

    // Added so that this function may receive ETH in the event of stuck transactions.
    receive() external payable {}

    /**
     * @notice When called by the cross domain admin (i.e. the hub pool), the msg.data should be some function
     * recognizable by the L3 spoke pool, such as "relayRootBundle" or "upgradeTo". Therefore, we simply forward
     * this message to the L3 spoke pool using the implemented messaging logic of the L2 forwarder.
     */
    fallback() external payable onlyAdmin {
        _relayL3Message(l3SpokePool, msg.data);
    }

    /**
     * @notice Sets a new cross domain admin for this contract.
     * @param _newCrossDomainAdmin L1 address of the new cross domain admin.
     */
    function setCrossDomainAdmin(address _newCrossDomainAdmin) external onlyAdmin {
        _setCrossDomainAdmin(_newCrossDomainAdmin);
    }

    /**
     * @notice Sets a new spoke pool address.
     * @param _newL3SpokePool L3 address of the new spoke pool contract.
     */
    function setL3SpokePool(address _newL3SpokePool) external onlyAdmin {
        _setL3SpokePool(_newL3SpokePool);
    }

    /**
     * @notice Bridge tokens to an L3.
     * @notice relayTokens should only send tokens to L3_SPOKE_POOL, so no access control is required.
     * @param l2Token L2 token to deposit.
     * @param l3Token L3 token to receive on the destination chain.
     * @param amount Amount of L2 tokens to deposit and L3 tokens to receive.
     */
    function relayTokens(
        address l2Token,
        address l3Token,
        uint256 amount
    ) external payable virtual;

    /**
     * @notice Relay a message to a contract on L3. Implementation changes on whether the
     * @notice This function should be implmented differently based on whether the L2-L3 bridge
     * requires custom gas tokens to fund cross-chain transactions.
     */
    function _relayL3Message(address target, bytes memory message) internal virtual;

    // Function to be overridden to accomodate for each L2's unique method of address aliasing.
    function _requireAdminSender() internal virtual;

    // Use the same access control logic implemented in the forwarders to authorize an upgrade.
    function _authorizeUpgrade(address) internal virtual override onlyAdmin {}

    function _setCrossDomainAdmin(address _newCrossDomainAdmin) internal {
        if (_newCrossDomainAdmin == address(0)) revert InvalidCrossDomainAdmin();
        crossDomainAdmin = _newCrossDomainAdmin;
        emit SetXDomainAdmin(_newCrossDomainAdmin);
    }

    function _setL3SpokePool(address _newL3SpokePool) internal {
        if (_newL3SpokePool == address(0)) revert InvalidL3SpokePool();
        l3SpokePool = _newL3SpokePool;
        emit SetL3SpokePool(_newL3SpokePool);
    }
}
