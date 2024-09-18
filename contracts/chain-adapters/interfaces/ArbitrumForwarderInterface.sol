// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title Staging ground for incoming and outgoing messages
 * @notice Unlike the standard Eth bridge, native token bridge escrows the custom ERC20 token which is
 * used as native currency on L3.
 * @dev Fees are paid in this token. There are certain restrictions on the native token:
 *       - The token can't be rebasing or have a transfer fee
 *       - The token must only be transferrable via a call to the token address itself
 *       - The token must only be able to set allowance via a call to the token address itself
 *       - The token must not have a callback on transfer, and more generally a user must not be able to make a transfer to themselves revert
 *       - The token must have a max of 2^256 - 1 wei total supply unscaled
 *       - The token must have a max of 2^256 - 1 wei total supply when scaled to 18 decimals
 */
interface ArbitrumERC20Bridge {
    /**
     * @notice Returns token that is escrowed in bridge on L2 side and minted on L3 as native currency.
     * @dev This function doesn't exist on the generic Bridge interface.
     * @return address of the native token.
     */
    function nativeToken() external view returns (address);
}

/**
 * @title Inbox for user and contract originated messages
 * @notice Messages created via this inbox are enqueued in the delayed accumulator
 * to await inclusion in the SequencerInbox
 */
interface ArbitrumInboxLike {
    /**
     * @dev we only use this function to check the native token used by the bridge, so we hardcode the interface
     * to return an ArbitrumERC20Bridge instead of a more generic Bridge interface.
     * @return address of the bridge.
     */
    function bridge() external view returns (ArbitrumERC20Bridge);

    /**
     * @notice Put a message in the L2 inbox that can be reexecuted for some fixed amount of time if it reverts
     * @dev Gas limit and maxFeePerGas should not be set to 1 as that is used to trigger the RetryableData error
     * @dev Caller must set msg.value equal to at least `maxSubmissionCost + maxGas * gasPriceBid`.
     *      all msg.value will deposited to callValueRefundAddress on L3
     * @dev More details can be found here: https://developer.arbitrum.io/arbos/l1-to-l2-messaging
     * @param to destination L3 contract address
     * @param l3CallValue call value for retryable L3 message
     * @param maxSubmissionCost Max gas deducted from user's L3 balance to cover base submission fee
     * @param excessFeeRefundAddress gasLimit x maxFeePerGas - execution cost gets credited here on L3 balance
     * @param callValueRefundAddress l3Callvalue gets credited here on L3 if retryable txn times out or gets cancelled
     * @param gasLimit Max gas deducted from user's L3 balance to cover L3 execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param maxFeePerGas price bid for L3 execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param data ABI encoded data of L3 message
     * @return unique message number of the retryable transaction
     */
    function createRetryableTicket(
        address to,
        uint256 l3CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes calldata data
    ) external payable returns (uint256);

    /**
     * @notice Put a message in the L2 inbox that can be reexecuted for some fixed amount of time if it reverts
     * @notice Overloads the `createRetryableTicket` function but is not payable, and should only be called when paying
     * for L2 to L3 message using a custom gas token.
     * @dev all tokenTotalFeeAmount will be deposited to callValueRefundAddress on L3
     * @dev Gas limit and maxFeePerGas should not be set to 1 as that is used to trigger the RetryableData error
     * @dev In case of native token having non-18 decimals: tokenTotalFeeAmount is denominated in native token's decimals. All other value params - l3CallValue, maxSubmissionCost and maxFeePerGas are denominated in child chain's native 18 decimals.
     * @param to destination L3 contract address
     * @param l3CallValue call value for retryable L3 message
     * @param maxSubmissionCost Max gas deducted from user's L3 balance to cover base submission fee
     * @param excessFeeRefundAddress the address which receives the difference between execution fee paid and the actual execution cost. In case this address is a contract, funds will be received in its alias on L3.
     * @param callValueRefundAddress l3Callvalue gets credited here on L3 if retryable txn times out or gets cancelled. In case this address is a contract, funds will be received in its alias on L3.
     * @param gasLimit Max gas deducted from user's L3 balance to cover L3 execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param maxFeePerGas price bid for L3 execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param tokenTotalFeeAmount amount of fees to be deposited in native token to cover for retryable ticket cost
     * @param data ABI encoded data of L3 message
     * @return unique message number of the retryable transaction
     */
    function createRetryableTicket(
        address to,
        uint256 l3CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        uint256 tokenTotalFeeAmount,
        bytes calldata data
    ) external returns (uint256);
}

/**
 * @notice Generic gateway contract for bridging standard ERC20s to Arbitrum-like networks.
 */
interface ArbitrumERC20GatewayLike {
    /**
     * @notice Deposit ERC20 token from Ethereum into Arbitrum-like networks.
     * @dev L3 address alias will not be applied to the following types of addresses on L2:
     *      - an externally-owned account
     *      - a contract in construction
     *      - an address where a contract will be created
     *      - an address where a contract lived, but was destroyed
     * @param _l2Token L2 address of ERC20
     * @param _refundTo Account, or its L3 alias if it have code in L2, to be credited with excess gas refund in L3
     * @param _to Account to be credited with the tokens in the L3 (can be the user's L3 account or a contract),
     * not subject to L3 aliasing. This account, or its L3 alias if it have code in L2, will also be able to
     * cancel the retryable ticket and receive callvalue refund
     * @param _amount Token Amount
     * @param _maxGas Max gas deducted from user's L3 balance to cover L3 execution
     * @param _gasPriceBid Gas price for L3 execution
     * @param _data encoded data from router and user
     * @return res abi encoded inbox sequence number
     */
    function outboundTransferCustomRefund(
        address _l2Token,
        address _refundTo,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory);

    /**
     * @notice get ERC20 gateway for token.
     * @param _token ERC20 address.
     * @return address of ERC20 gateway.
     */
    function getGateway(address _token) external view returns (address);
}

/**
 * @notice Contract containing logic to send messages from L2 to Arbitrum-like L3s.
 * @dev This contract is meant to share code for Arbitrum L2 forwarder contracts deployed to various
 * different L2 architectures (e.g. Base, Arbitrum, ZkSync, etc.). It assumes that the L3 conforms
 * to an Arbitrum-like interface.
 */

// solhint-disable-next-line contract-name-camelcase
abstract contract ArbitrumForwarderInterface {
    // Amount of gas token allocated to pay for the base submission fee. The base submission fee is a parameter unique to
    // retryable transactions; the user is charged the base submission fee to cover the storage costs of keeping their
    // ticket’s calldata in the retry buffer. (current base submission fee is queryable via
    // ArbRetryableTx.getSubmissionPrice). ArbRetryableTicket precompile interface exists at L2 address
    // 0x000000000000000000000000000000000000006E.
    // @dev This is immutable because we don't know what precision the custom gas token has.
    uint256 public immutable L3_MAX_SUBMISSION_COST;

    // L3 Gas price bid for immediate L3 execution attempt (queryable via standard eth*gasPrice RPC)
    uint256 public constant L3_GAS_PRICE = 5e9; // 5 gWei

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
    address public immutable crossDomainAdmin;

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
        address _l3SpokePool,
        address _crossDomainAdmin
    ) {
        L2_INBOX = _l2ArbitrumInbox;
        L2_ERC20_GATEWAY_ROUTER = _l2ERC20GatewayRouter;
        L3_REFUND_L3_ADDRESS = _l3RefundL3Address;
        L3_MAX_SUBMISSION_COST = _l3MaxSubmissionCost;
        L3_SPOKE_POOL = _l3SpokePool;
        crossDomainAdmin = _crossDomainAdmin;
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
     * @notice This function can only be called via a rescue adapter, and is used to recover potentially stuck
     * funds on this contract.
     */
    function rescue(
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
