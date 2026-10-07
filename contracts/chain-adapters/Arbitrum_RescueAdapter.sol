// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import { ArbitrumInboxLike as ArbitrumL1InboxLike } from "../interfaces/ArbitrumBridge.sol";

/**
 * @notice Meant to copy the Arbitrum_Adapter exactly in how it sends L1 --> L2 messages but is designed only to be
 * used by the owner of the HubPool to retrieve ETH held by its aliased address on L2. This ETH builds up because
 * `relayTokens` calls `l1ERC20GatewayRouter.outboundTransfer` which does not allow the caller to specify an L2 refund
 * address the same way that `l1Inbox.createRetryableTicket` does. This means that the alias address of the caller, the
 * HubPool in this case, receives ETH on L2. This Adapter can be used to send messages to Arbitrum specifically to send
 * transactions as if called by the aliased HubPool address.
 * @dev Intended usage: the HubPool owner registers this adapter via `setCrossChainContracts`, calls
 * `relaySpokePoolAdminFunction(chainId, abi.encode(amountToRescue))`, and restores the production adapter, all in one
 * atomic batch. The rescued ETH and all fee refunds are sent to the immutable `l2Recipient`.
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_RescueAdapter is AdapterInterface {
    // Amount of ETH allocated to pay for the base submission fee. The base submission fee is a parameter unique to
    // retryable transactions; the user is charged the base submission fee to cover the storage costs of keeping their
    // ticket's calldata in the retry buffer. (current base submission fee is queryable via
    // Inbox.calculateRetryableSubmissionFee). Any excess is refunded to `l2Recipient` on L2.
    uint256 public immutable l2MaxSubmissionCost = 0.01e18;

    // L2 gas price bid for immediate L2 execution attempt (queryable via standard eth_gasPrice RPC). Any excess over
    // the gas actually paid is refunded to `l2Recipient` on L2.
    uint256 public immutable l2GasPrice = 5e9; // 5 gWei

    // Gas limit for immediate L2 execution attempt (can be estimated via NodeInterface.estimateRetryableTicket).
    // NodeInterface precompile interface exists at L2 address 0x00000000000000000000000000000000000000C8
    uint32 public immutable l2GasLimit = 2_000_000;

    // This L2 address receives the rescued ETH as well as all submission fee and gas refunds.
    address public immutable l2Recipient;

    // L1 HubPool address aliased on L2:
    // https://docs.arbitrum.io/how-arbitrum-works/l1-to-l2-messaging#address-aliasing
    address public immutable aliasedL2HubPoolAddress = 0xd297fA914353c44B2e33EBE05F21846f1048CFeB;

    ArbitrumL1InboxLike public immutable l1Inbox;

    error InvalidL2Recipient();

    /**
     * @notice Constructs new Adapter.
     * @param _l1ArbitrumInbox Inbox helper contract to send messages to Arbitrum.
     * @param _l2Recipient L2 address that receives the rescued ETH and all fee refunds.
     */
    constructor(ArbitrumL1InboxLike _l1ArbitrumInbox, address _l2Recipient) {
        if (_l2Recipient == address(0)) revert InvalidL2Recipient();
        l1Inbox = _l1ArbitrumInbox;
        l2Recipient = _l2Recipient;
    }

    /**
     * @notice Send cross-chain message to aliased hub pool address on Arbitrum.
     * @notice The caller (the HubPool, since this adapter is delegatecalled) must hold at least getL1CallValue()
     * amount of ETH to send a message via the Inbox successfully, or the message will get stuck.
     * @param message ABI-encoded amount of ETH (uint256) to rescue from the aliased hub pool address.
     */
    function relayMessage(address, bytes memory message) external payable override {
        uint256 valueToReturn = abi.decode(message, (uint256));

        uint256 requiredL1CallValue = _contractHasSufficientEthBalance();

        // In the rescue ETH setup, we send the transaction to the recipient, we provide a call value equal to the
        // amount we want to rescue, and we specify an empty calldata, since it's a simple ETH transfer.
        // Note: we use the unsafe version of createRetryableTicket because it doesn't require msg.value to cover
        // l2CallValue in addition to maxSubmissionCost + gasLimit * maxFeePerGas. The l2CallValue is instead deducted
        // from the aliased sender's L2 balance, which is exactly where the ETH being rescued sits.
        l1Inbox.unsafeCreateRetryableTicket{ value: requiredL1CallValue }(
            l2Recipient, // to destination L2 address
            valueToReturn, // l2CallValue call value for retryable L2 message
            l2MaxSubmissionCost, // maxSubmissionCost Max gas deducted from user's L2 balance to cover base fee
            l2Recipient, // excessFeeRefundAddress gasLimit * maxFeePerGas - execution cost gets credited here on L2
            l2Recipient, // callValueRefundAddress l2CallValue gets credited here on L2 if retryable txn times out or gets cancelled
            l2GasLimit, // gasLimit Max gas deducted from user's L2 balance to cover L2 execution
            l2GasPrice, // maxFeePerGas price bid for L2 execution
            "" // data ABI encoded data of L2 message
        );

        emit MessageRelayed(aliasedL2HubPoolAddress, "");
    }

    /**
     * @notice Should never be called.
     */
    function relayTokens(address, address, uint256, address) external payable override {
        revert("useless function");
    }

    /**
     * @notice Returns required amount of ETH to send a message via the Inbox.
     * @return amount of ETH that this contract needs to hold in order for relayMessage to succeed.
     */
    function getL1CallValue() public pure returns (uint256) {
        return l2MaxSubmissionCost + l2GasPrice * l2GasLimit;
    }

    function _contractHasSufficientEthBalance() internal view returns (uint256 requiredL1CallValue) {
        requiredL1CallValue = getL1CallValue();
        require(address(this).balance >= requiredL1CallValue, "Insufficient ETH balance");
    }
}
