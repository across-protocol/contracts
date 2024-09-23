// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ArbitrumERC20Bridge, ArbitrumInboxLike, ArbitrumERC20GatewayLike } from "../interfaces/ArbitrumBridgeInterfaces.sol";

// solhint-disable-next-line contract-name-camelcase
abstract contract ArbitrumForwarderBase {
    // Amount of gas token allocated to pay for the base submission fee. The base submission fee is a parameter unique to
    // retryable transactions; the user is charged the base submission fee to cover the storage costs of keeping their
    // ticket’s calldata in the retry buffer. (current base submission fee is queryable via
    // ArbRetryableTx.getSubmissionPrice). ArbRetryableTicket precompile interface exists at L2 address
    // 0x000000000000000000000000000000000000006E.
    // @dev This is immutable because we don't know what precision the custom gas token has.
    uint256 public immutable L3_MAX_SUBMISSION_COST;

    // L3 Gas price bid for immediate L3 execution attempt (queryable via standard eth*gasPrice RPC)
    uint256 public immutable L3_GAS_PRICE; // The standard is 5 gWei

    // Native token expected to be sent in L3 message. Should be 0 for all use cases of this constant, which
    // includes sending messages from L2 to L3 and sending Custom gas token ERC20's, which won't be the native token
    // on the L3 by definition.
    uint256 public constant L3_CALL_VALUE = 0;

    // Gas limit for L3 execution of a cross chain token transfer sent via the inbox.
    uint32 public constant RELAY_TOKENS_L3_GAS_LIMIT = 300_000;
    // Gas limit for L3 execution of a message sent via the inbox.
    uint32 public constant RELAY_MESSAGE_L3_GAS_LIMIT = 2_000_000;

    // This address on L3 receives extra gas token that is left over after relaying a message via the inbox.
    address public immutable L3_REFUND_L3_ADDRESS;

    // This is the address which receives messages and tokens on L3, assumed to be the spoke pool.
    address public immutable L3_SPOKE_POOL;

    // This is the address which has permission to relay root bundles/messages to the L3 spoke pool.
    address public immutable CROSS_DOMAIN_ADMIN;

    // Inbox system contract to send messages to Arbitrum-like L3s. Token bridges use this to send tokens to L3.
    // https://github.com/OffchainLabs/nitro-contracts/blob/f7894d3a6d4035ba60f51a7f1334f0f2d4f02dce/src/bridge/Inbox.sol
    ArbitrumInboxLike public immutable L2_INBOX;

    // Router contract to send tokens to Arbitrum. Routes to correct gateway to bridge tokens. Internally this
    // contract calls the Inbox.
    // Generic gateway: https://github.com/OffchainLabs/token-bridge-contracts/blob/main/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol
    // Gateway used for communicating with chains that use custom gas tokens:
    // https://github.com/OffchainLabs/token-bridge-contracts/blob/main/contracts/tokenbridge/ethereum/gateway/L1ERC20Gateway.sol
    ArbitrumERC20GatewayLike public immutable L2_ERC20_GATEWAY_ROUTER;

    event TokensForwarded(address indexed l2Token, uint256 amount);
    event MessageForwarded(address indexed target, bytes message);

    error RescueFailed();

    /*
     * @dev All functions with this modifier must revert if msg.sender != CROSS_DOMAIN_ADMIN, but each L2 may have
     * unique aliasing logic, so it is up to the forwarder contract to verify that the sender is valid.
     */
    modifier onlyAdmin() {
        _requireAdminSender();
        _;
    }

    /**
     * @notice Constructs new Adapter.
     * @param _l2ArbitrumInbox Inbox helper contract to send messages to Arbitrum-like L3s.
     * @param _l2ERC20GatewayRouter ERC20 gateway router contract to send tokens to Arbitrum-like L3s.
     * @param _l3RefundL3Address L3 address to receive gas refunds on after a message is relayed.
     * @param _l3MaxSubmissionCost Amount of gas token allocated to pay for the base submission fee. The base
     * submission fee is a parameter unique to Arbitrum retryable transactions. This value is hardcoded
     * and used for all messages sent by this adapter.
     * @param _l3SpokePool L3 address of the contract which will receive messages and tokens which are temporarily
     * stored in this contract on L2.
     * @param _crossDomainAdmin L1 address of the contract which can send root bundles/messages to this forwarder contract.
     * In practice, this is the hub pool.
     */
    constructor(
        ArbitrumInboxLike _l2ArbitrumInbox,
        ArbitrumERC20GatewayLike _l2ERC20GatewayRouter,
        address _l3RefundL3Address,
        uint256 _l3MaxSubmissionCost,
        uint256 _l3GasPrice,
        address _l3SpokePool,
        address _crossDomainAdmin
    ) {
        L2_INBOX = _l2ArbitrumInbox;
        L2_ERC20_GATEWAY_ROUTER = _l2ERC20GatewayRouter;
        L3_REFUND_L3_ADDRESS = _l3RefundL3Address;
        L3_MAX_SUBMISSION_COST = _l3MaxSubmissionCost;
        L3_GAS_PRICE = _l3GasPrice;
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
        _relayMessage(L3_SPOKE_POOL, msg.data);
    }

    /**
     * @notice This function can only be called via a rescue adapter. It is used to recover potentially stuck
     * funds on this contract.
     */
    function adminCall(
        address target,
        uint256 value,
        bytes memory message
    ) external onlyAdmin {
        (bool success, ) = target.call{ value: value }(message);
        if (!success) revert RescueFailed();
    }

    /**
     * @notice Bridge tokens to an Arbitrum-like L3.
     * @notice This contract must hold at least getL2CallValue() amount of ETH or custom gas token
     * to send a message via the Inbox successfully, or the message will get stuck.
     * @notice relayTokens should only send tokens to L3_SPOKE_POOL, so no access control is required.
     * @param l2Token L2 token to deposit.
     * @param amount Amount of L2 tokens to deposit and L3 tokens to receive.
     */
    function relayTokens(address l2Token, uint256 amount) external payable virtual;

    /**
     * @notice Relay a message to a contract on L2. Implementation changes on whether the
     * target bridge supports a custom gas token or not.
     * @notice This contract must hold at least getL2CallValue() amount of the custom gas token
     * to send a message via the Inbox successfully, or the message will get stuck.
     * @notice This function should be implmented differently based on whether the L2-L3 bridge
     * requires custom gas tokens to fund cross-chain transactions.
     */
    function _relayMessage(address target, bytes memory message) internal virtual;

    // Function to be overridden to accomodate for each L2's unique method of address aliasing.
    function _requireAdminSender() internal virtual;

    /**
     * @notice Returns required amount of gas token to send a message via the Inbox.
     * @param l3GasLimit L3 gas limit for the message.
     * @return amount of gas token that this contract needs to hold in order for relayMessage to succeed.
     */
    function getL2CallValue(uint32 l3GasLimit) public view returns (uint256) {
        return L3_MAX_SUBMISSION_COST + L3_GAS_PRICE * l3GasLimit;
    }
}
