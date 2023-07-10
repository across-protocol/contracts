// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "./Arbitrum_Adapter.sol"; // Used to import `ArbitrumL1ERC20GatewayLike` and `ArbitrumL1InboxLike`

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Meant to copy the Arbitrum_Adapter exactly in how it sends L1 --> L2 messages but is designed only to be
 * used by the owner of the HubPool to retrieve ETH held by its aliased address on L2. This ETH builds up because
 * `relayTokens` calls `l1ERC20GatewayRouter.outboundTransfer` which does not allow the caller to specify an L2 refund
 * address the same way that `l1Inbox.createRetryableTicket` does. This means that the alias address of the caller, the
 * HubPool in this case, receives ETH on L2. This Adapter can be used to send messages to Arbitrum specifically to send
 * transactions as if called by the aliased HubPool address.
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_RescueAdapter is AdapterInterface {
    using SafeERC20 for IERC20;

    // Amount of ETH allocated to pay for the base submission fee. The base submission fee is a parameter unique to
    // retryable transactions; the user is charged the base submission fee to cover the storage costs of keeping their
    // ticket’s calldata in the retry buffer. (current base submission fee is queryable via
    // ArbRetryableTx.getSubmissionPrice). ArbRetryableTicket precompile interface exists at L2 address
    // 0x000000000000000000000000000000000000006E.
    uint256 public immutable l2MaxSubmissionCost = 0.01e18;

    // L2 Gas price bid for immediate L2 execution attempt (queryable via standard eth*gasPrice RPC)
    uint256 public immutable l2GasPrice = 5e9; // 5 gWei

    // Gas limit for immediate L2 execution attempt (can be estimated via NodeInterface.estimateRetryableTicket).
    // NodeInterface precompile interface exists at L2 address 0x00000000000000000000000000000000000000C8
    uint32 public immutable l2GasLimit = 2_000_000;

    // This address on L2 receives extra ETH that is left over after relaying a message via the inbox.
    address public immutable l2RefundL2Address;

    // L1 HubPool address aliased on L2: https://github.com/OffchainLabs/arbitrum/blob/master/docs/L1_L2_Messages.md#address-aliasing
    address public immutable aliasedL2HubPoolAddress = 0xd297fA914353c44B2e33EBE05F21846f1048CFeB;

    ArbitrumL1InboxLike public immutable l1Inbox;

    /**
     * @notice Constructs new Adapter.
     * @param _l1ArbitrumInbox Inbox helper contract to send messages to Arbitrum.
     */
    constructor(ArbitrumL1InboxLike _l1ArbitrumInbox) {
        l1Inbox = _l1ArbitrumInbox;

        l2RefundL2Address = msg.sender;
    }

    /**
     * @notice Send cross-chain message to aliased hub pool address on Arbitrum.
     * @notice This contract must hold at least getL1CallValue() amount of ETH to send a message via the Inbox
     * successfully, or the message will get stuck.
     * @param message Data to send to aliased hub pool.
     */
    function relayMessage(address, bytes memory message) external payable override {
        uint256 valueToReturn = abi.decode(message, (uint256));

        uint256 requiredL1CallValue = _contractHasSufficientEthBalance();

        // In the rescue ETH setup, we send the transaction to the refund address, we provide a call value equal to the
        // amount we want to rescue, and we specify an empty calldata, since it's a simple ETH transfer.
        // Note: we use the unsafe version of createRetryableTicket because it doesn't require the msg.sender to pass
        // in arbTxCallValue in addition to maxSubmissionCost + maxGas * gasPriceBid.
        l1Inbox.unsafeCreateRetryableTicket{ value: requiredL1CallValue }(
            l2RefundL2Address, // destAddr destination L2 contract address
            valueToReturn, // l2CallValue call value for retryable L2 message
            l2MaxSubmissionCost, // maxSubmissionCost Max gas deducted from user's L2 balance to cover base fee
            l2RefundL2Address, // excessFeeRefundAddress maxgas * gasprice - execution cost gets credited here on L2
            l2RefundL2Address, // callValueRefundAddress l2Callvalue gets credited here on L2 if retryable txn times out or gets cancelled
            l2GasLimit, // maxGas Max gas deducted from user's L2 balance to cover L2 execution
            l2GasPrice, // gasPriceBid price bid for L2 execution
            "" // data ABI encoded data of L2 message
        );

        emit MessageRelayed(aliasedL2HubPoolAddress, "");
    }

    /**
     * @notice Should never be called.
     */
    function relayTokens(
        address,
        address,
        uint256,
        address
    ) external payable override {
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
