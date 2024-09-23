// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

abstract contract ForwarderBase {
    address public immutable L3_SPOKE_POOL;
    address public immutable CROSS_DOMAIN_ADMIN;

    event TokensForwarded(address indexed l2Token, uint256 amount);
    event MessageForwarded(address indexed target, bytes message);

    /*
     * @dev All functions with this modifier must revert if msg.sender != CROSS_DOMAIN_ADMIN, but each L2 may have
     * unique aliasing logic, so it is up to the forwarder contract to verify that the sender is valid.
     */
    modifier onlyAdmin() {
        _requireAdminSender();
        _;
    }

    /**
     * @notice Constructs new Forwarder.
     * @param _l3SpokePool L3 address of the contract which will receive messages and tokens which are temporarily
     * stored in this contract on L2.
     * @param _crossDomainAdmin L1 address of the contract which can send root bundles/messages to this forwarder contract.
     * In practice, this is the hub pool.
     */
    constructor(address _l3SpokePool, address _crossDomainAdmin) {
        L3_SPOKE_POOL = _l3SpokePool;
        CROSS_DOMAIN_ADMIN = _crossDomainAdmin;
    }

    // Added so that this function may receive ETH in the event of stuck transactions.
    receive() external payable {}

    /**
     * @notice When called by the cross domain admin (i.e. the hub pool), the msg.data should be some function
     * recognizable by the L3 spoke pool, such as "relayRootBundle" or "upgradeTo". Therefore, we simply forward
     * this message to the L3 spoke pool using the implemented messaging logic of the L2 forwarder
     */
    fallback() external payable onlyAdmin {
        _relayL3Message(L3_SPOKE_POOL, msg.data);
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
}
