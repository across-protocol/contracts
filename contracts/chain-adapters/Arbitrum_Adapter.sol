// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/AdapterInterface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ArbitrumL1InboxLike {
    function createRetryableTicket(
        address destAddr,
        uint256 arbTxCallValue,
        uint256 maxSubmissionCost,
        address submissionRefundAddress,
        address valueRefundAddress,
        uint256 maxGas,
        uint256 gasPriceBid,
        bytes calldata data
    ) external payable returns (uint256);
}

interface ArbitrumL1ERC20GatewayLike {
    function outboundTransfer(
        address _token,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory);

    function outboundTransferCustomRefund(
        address _token,
        address _refundTo,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory);

    function getGateway(address _token) external view returns (address);
}

/**
 * @notice Contract containing logic to send messages from L1 to Arbitrum.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;

    // Amount of ETH allocated to pay for the base submission fee. The base submission fee is a parameter unique to
    // retryable transactions; the user is charged the base submission fee to cover the storage costs of keeping their
    // ticket’s calldata in the retry buffer. (current base submission fee is queryable via
    // ArbRetryableTx.getSubmissionPrice). ArbRetryableTicket precompile interface exists at L2 address
    // 0x000000000000000000000000000000000000006E.
    uint256 public constant l2MaxSubmissionCost = 0.01e18;

    // L2 Gas price bid for immediate L2 execution attempt (queryable via standard eth*gasPrice RPC)
    uint256 public constant l2GasPrice = 5e9; // 5 gWei

    uint32 public constant RELAY_TOKENS_L2_GAS_LIMIT = 300_000;
    uint32 public constant RELAY_MESSAGE_L2_GAS_LIMIT = 2_000_000;

    // This address on L2 receives extra ETH that is left over after relaying a message via the inbox.
    address public constant l2RefundL2Address = 0x428AB2BA90Eba0a4Be7aF34C9Ac451ab061AC010;

    ArbitrumL1InboxLike public immutable l1Inbox;

    ArbitrumL1ERC20GatewayLike public immutable l1ERC20GatewayRouter;

    /**
     * @notice Constructs new Adapter.
     * @param _l1ArbitrumInbox Inbox helper contract to send messages to Arbitrum.
     * @param _l1ERC20GatewayRouter ERC20 gateway router contract to send tokens to Arbitrum.
     */
    constructor(ArbitrumL1InboxLike _l1ArbitrumInbox, ArbitrumL1ERC20GatewayLike _l1ERC20GatewayRouter) {
        l1Inbox = _l1ArbitrumInbox;
        l1ERC20GatewayRouter = _l1ERC20GatewayRouter;
    }

    /**
     * @notice Send cross-chain message to target on Arbitrum.
     * @notice This contract must hold at least getL1CallValue() amount of ETH to send a message via the Inbox
     * successfully, or the message will get stuck.
     * @param target Contract on Arbitrum that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        uint256 requiredL1CallValue = _contractHasSufficientEthBalance(RELAY_MESSAGE_L2_GAS_LIMIT);

        l1Inbox.createRetryableTicket{ value: requiredL1CallValue }(
            target, // destAddr destination L2 contract address
            0, // l2CallValue call value for retryable L2 message
            l2MaxSubmissionCost, // maxSubmissionCost Max gas deducted from user's L2 balance to cover base fee
            l2RefundL2Address, // excessFeeRefundAddress maxgas * gasprice - execution cost gets credited here on L2
            l2RefundL2Address, // callValueRefundAddress l2Callvalue gets credited here on L2 if retryable txn times out or gets cancelled
            RELAY_MESSAGE_L2_GAS_LIMIT, // maxGas Max gas deducted from user's L2 balance to cover L2 execution
            l2GasPrice, // gasPriceBid price bid for L2 execution
            message // data ABI encoded data of L2 message
        );

        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Arbitrum.
     * @notice This contract must hold at least getL1CallValue() amount of ETH to send a message via the Inbox
     * successfully, or the message will get stuck.
     * @param l1Token L1 token to deposit.
     * @param l2Token L2 token to receive.
     * @param amount Amount of L1 tokens to deposit and L2 tokens to receive.
     * @param to Bridge recipient.
     */
    function relayTokens(
        address l1Token,
        address l2Token, // l2Token is unused for Arbitrum.
        uint256 amount,
        address to
    ) external payable override {
        uint256 requiredL1CallValue = _contractHasSufficientEthBalance(RELAY_TOKENS_L2_GAS_LIMIT);

        // Approve the gateway, not the router, to spend the hub pool's balance. The gateway, which is different
        // per L1 token, will temporarily escrow the tokens to be bridged and pull them from this contract.
        address erc20Gateway = l1ERC20GatewayRouter.getGateway(l1Token);
        IERC20(l1Token).safeIncreaseAllowance(erc20Gateway, amount);

        // `outboundTransfer` expects that the caller includes a bytes message as the last param that includes the
        // maxSubmissionCost to use when creating an L2 retryable ticket: https://github.com/OffchainLabs/arbitrum/blob/e98d14873dd77513b569771f47b5e05b72402c5e/packages/arb-bridge-peripherals/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol#L232
        bytes memory data = abi.encode(l2MaxSubmissionCost, "");

        // Note: Legacy routers don't have the outboundTransferCustomRefund method, so default to using
        // outboundTransfer(). Legacy routers are used for the following tokens that are currently enabled:
        // - DAI
        if (l1Token == 0x6B175474E89094C44Da98b954EedeAC495271d0F) {
            // Note: outboundTransfer() will ultimately create a retryable ticket and set this contract's address as the
            // refund address. This means that the excess ETH to pay for the L2 transaction will be sent to the aliased
            // contract address on L2, which we'd have to retrieve via a custom adapter
            // (i.e. the Arbitrum_RescueAdapter).
            l1ERC20GatewayRouter.outboundTransfer{ value: requiredL1CallValue }(
                l1Token,
                to,
                amount,
                RELAY_TOKENS_L2_GAS_LIMIT,
                l2GasPrice,
                data
            );
        } else {
            l1ERC20GatewayRouter.outboundTransferCustomRefund{ value: requiredL1CallValue }(
                l1Token,
                l2RefundL2Address,
                to,
                amount,
                RELAY_TOKENS_L2_GAS_LIMIT,
                l2GasPrice,
                data
            );
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }

    /**
     * @notice Returns required amount of ETH to send a message via the Inbox.
     * @return amount of ETH that this contract needs to hold in order for relayMessage to succeed.
     */
    function getL1CallValue(uint32 l2GasLimit) public pure returns (uint256) {
        return l2MaxSubmissionCost + l2GasPrice * l2GasLimit;
    }

    function _contractHasSufficientEthBalance(uint32 l2GasLimit) internal view returns (uint256 requiredL1CallValue) {
        requiredL1CallValue = getL1CallValue(l2GasLimit);
        require(address(this).balance >= requiredL1CallValue, "Insufficient ETH balance");
    }
}
