// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../external/interfaces/CCTPInterfaces.sol";
import "../libraries/CircleCCTPAdapter.sol";

/**
 * @notice Interface for Arbitrum's L1 Inbox contract used to send messages to Arbitrum.
 * @custom:security-contact bugs@across.to
 */
interface ArbitrumL1InboxLike {
    /**
     * @notice Put a message in the L2 inbox that can be reexecuted for some fixed amount of time if it reverts
     * @dev Gas limit and maxFeePerGas should not be set to 1 as that is used to trigger the RetryableData error
     * @dev Caller must set msg.value equal to at least `maxSubmissionCost + maxGas * gasPriceBid`.
     *      all msg.value will deposited to callValueRefundAddress on L2
     * @dev More details can be found here: https://developer.arbitrum.io/arbos/l1-to-l2-messaging
     * @param to destination L2 contract address
     * @param l2CallValue call value for retryable L2 message
     * @param maxSubmissionCost Max gas deducted from user's L2 balance to cover base submission fee
     * @param excessFeeRefundAddress gasLimit x maxFeePerGas - execution cost gets credited here on L2 balance
     * @param callValueRefundAddress l2Callvalue gets credited here on L2 if retryable txn times out or gets cancelled
     * @param gasLimit Max gas deducted from user's L2 balance to cover L2 execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param maxFeePerGas price bid for L2 execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param data ABI encoded data of L2 message
     * @return unique message number of the retryable transaction
     */
    function createRetryableTicket(
        address to,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes calldata data
    ) external payable returns (uint256);

    /**
     * @notice Put a message in the L2 inbox that can be reexecuted for some fixed amount of time if it reverts
     * @dev Same as createRetryableTicket, but does not guarantee that submission will succeed by requiring the needed
     * funds come from the deposit alone, rather than falling back on the user's L2 balance
     * @dev Advanced usage only (does not rewrite aliases for excessFeeRefundAddress and callValueRefundAddress).
     * createRetryableTicket method is the recommended standard.
     * @dev Gas limit and maxFeePerGas should not be set to 1 as that is used to trigger the RetryableData error
     * @param to destination L2 contract address
     * @param l2CallValue call value for retryable L2 message
     * @param maxSubmissionCost Max gas deducted from user's L2 balance to cover base submission fee
     * @param excessFeeRefundAddress gasLimit x maxFeePerGas - execution cost gets credited here on L2 balance
     * @param callValueRefundAddress l2Callvalue gets credited here on L2 if retryable txn times out or gets cancelled
     * @param gasLimit Max gas deducted from user's L2 balance to cover L2 execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param maxFeePerGas price bid for L2 execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param data ABI encoded data of L2 message
     * @return unique message number of the retryable transaction
     */
    function unsafeCreateRetryableTicket(
        address to,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes calldata data
    ) external payable returns (uint256);
}

/**
 * @notice Layer 1 Gateway contract for bridging standard ERC20s to Arbitrum.
 */
interface ArbitrumL1ERC20GatewayLike {
    /**
     * @notice Deprecated in favor of outboundTransferCustomRefund but still used in custom bridges
     * like the DAI bridge.
     * @dev Refunded to aliased L2 address of sender if sender has code on L1, otherwise to to sender's EOA on L2.
     * @param _l1Token L1 address of ERC20
     * @param _to Account to be credited with the tokens in the L2 (can be the user's L2 account or a contract),
     * not subject to L2 aliasing. This account, or its L2 alias if it have code in L1, will also be able to
     * cancel the retryable ticket and receive callvalue refund
     * @param _amount Token Amount
     * @param _maxGas Max gas deducted from user's L2 balance to cover L2 execution
     * @param _gasPriceBid Gas price for L2 execution
     * @param _data encoded data from router and user
     * @return res abi encoded inbox sequence number
     */
    function outboundTransfer(
        address _l1Token,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory);

    /**
     * @notice Deposit ERC20 token from Ethereum into Arbitrum.
     * @dev L2 address alias will not be applied to the following types of addresses on L1:
     *      - an externally-owned account
     *      - a contract in construction
     *      - an address where a contract will be created
     *      - an address where a contract lived, but was destroyed
     * @param _l1Token L1 address of ERC20
     * @param _refundTo Account, or its L2 alias if it have code in L1, to be credited with excess gas refund in L2
     * @param _to Account to be credited with the tokens in the L2 (can be the user's L2 account or a contract),
     * not subject to L2 aliasing. This account, or its L2 alias if it have code in L1, will also be able to
     * cancel the retryable ticket and receive callvalue refund
     * @param _amount Token Amount
     * @param _maxGas Max gas deducted from user's L2 balance to cover L2 execution
     * @param _gasPriceBid Gas price for L2 execution
     * @param _data encoded data from router and user
     * @return res abi encoded inbox sequence number
     */
    function outboundTransferCustomRefund(
        address _l1Token,
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
 * @notice Contract containing logic to send messages from L1 to Arbitrum.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_Adapter is AdapterInterface, CircleCCTPAdapter {
    using SafeERC20 for IERC20;

    // Amount of ETH allocated to pay for the base submission fee. The base submission fee is a parameter unique to
    // retryable transactions; the user is charged the base submission fee to cover the storage costs of keeping their
    // ticket’s calldata in the retry buffer. (current base submission fee is queryable via
    // ArbRetryableTx.getSubmissionPrice). ArbRetryableTicket precompile interface exists at L2 address
    // 0x000000000000000000000000000000000000006E.
    uint256 public constant L2_MAX_SUBMISSION_COST = 0.01e18;

    // L2 Gas price bid for immediate L2 execution attempt (queryable via standard eth*gasPrice RPC)
    uint256 public constant L2_GAS_PRICE = 5e9; // 5 gWei

    uint256 public constant L2_CALL_VALUE = 0;

    uint32 public constant RELAY_TOKENS_L2_GAS_LIMIT = 300_000;
    uint32 public constant RELAY_MESSAGE_L2_GAS_LIMIT = 2_000_000;

    address public constant L1_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // This address on L2 receives extra ETH that is left over after relaying a message via the inbox.
    address public immutable L2_REFUND_L2_ADDRESS;

    ArbitrumL1InboxLike public immutable L1_INBOX;

    ArbitrumL1ERC20GatewayLike public immutable L1_ERC20_GATEWAY_ROUTER;

    /**
     * @notice Constructs new Adapter.
     * @param _l1ArbitrumInbox Inbox helper contract to send messages to Arbitrum.
     * @param _l1ERC20GatewayRouter ERC20 gateway router contract to send tokens to Arbitrum.
     * @param _l2RefundL2Address L2 address to receive gas refunds on after a message is relayed.
     * @param _l1Usdc USDC address on L1.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     */
    constructor(
        ArbitrumL1InboxLike _l1ArbitrumInbox,
        ArbitrumL1ERC20GatewayLike _l1ERC20GatewayRouter,
        address _l2RefundL2Address,
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger
    ) CircleCCTPAdapter(_l1Usdc, _cctpTokenMessenger, CircleDomainIds.Arbitrum) {
        L1_INBOX = _l1ArbitrumInbox;
        L1_ERC20_GATEWAY_ROUTER = _l1ERC20GatewayRouter;
        L2_REFUND_L2_ADDRESS = _l2RefundL2Address;
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

        L1_INBOX.createRetryableTicket{ value: requiredL1CallValue }(
            target, // destAddr destination L2 contract address
            L2_CALL_VALUE, // l2CallValue call value for retryable L2 message
            L2_MAX_SUBMISSION_COST, // maxSubmissionCost Max gas deducted from user's L2 balance to cover base fee
            L2_REFUND_L2_ADDRESS, // excessFeeRefundAddress maxgas * gasprice - execution cost gets credited here on L2
            L2_REFUND_L2_ADDRESS, // callValueRefundAddress l2Callvalue gets credited here on L2 if retryable txn times out or gets cancelled
            RELAY_MESSAGE_L2_GAS_LIMIT, // maxGas Max gas deducted from user's L2 balance to cover L2 execution
            L2_GAS_PRICE, // gasPriceBid price bid for L2 execution
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
        // Check if this token is USDC, which requires a custom bridge via CCTP.
        if (_isCCTPEnabled() && l1Token == address(usdcToken)) {
            _transferUsdc(to, amount);
        }
        // If not, we can use the Arbitrum gateway
        else {
            uint256 requiredL1CallValue = _contractHasSufficientEthBalance(RELAY_TOKENS_L2_GAS_LIMIT);

            // Approve the gateway, not the router, to spend the hub pool's balance. The gateway, which is different
            // per L1 token, will temporarily escrow the tokens to be bridged and pull them from this contract.
            address erc20Gateway = L1_ERC20_GATEWAY_ROUTER.getGateway(l1Token);
            IERC20(l1Token).safeIncreaseAllowance(erc20Gateway, amount);

            // `outboundTransfer` expects that the caller includes a bytes message as the last param that includes the
            // maxSubmissionCost to use when creating an L2 retryable ticket: https://github.com/OffchainLabs/arbitrum/blob/e98d14873dd77513b569771f47b5e05b72402c5e/packages/arb-bridge-peripherals/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol#L232
            bytes memory data = abi.encode(L2_MAX_SUBMISSION_COST, "");

            // Note: Legacy routers don't have the outboundTransferCustomRefund method, so default to using
            // outboundTransfer(). Legacy routers are used for the following tokens that are currently enabled:
            // - DAI: the implementation of `outboundTransfer` at the current DAI custom gateway
            //        (https://etherscan.io/address/0xD3B5b60020504bc3489D6949d545893982BA3011#writeContract) sets the
            //        sender as the refund address so the aliased HubPool should receive excess funds. Implementation here:
            //        https://github.com/makerdao/arbitrum-dai-bridge/blob/11a80385e2622968069c34d401b3d54a59060e87/contracts/l1/L1DaiGateway.sol#L109
            if (l1Token == L1_DAI) {
                // This means that the excess ETH to pay for the L2 transaction will be sent to the aliased
                // contract address on L2, which we'd have to retrieve via a custom adapter, the Arbitrum_RescueAdapter.
                // To do so, in a single transaction: 1) setCrossChainContracts to Arbitrum_RescueAdapter, 2) relayMessage
                // with function data = abi.encode(amountToRescue), 3) setCrossChainContracts back to this adapter.
                L1_ERC20_GATEWAY_ROUTER.outboundTransfer{ value: requiredL1CallValue }(
                    l1Token,
                    to,
                    amount,
                    RELAY_TOKENS_L2_GAS_LIMIT,
                    L2_GAS_PRICE,
                    data
                );
            } else {
                L1_ERC20_GATEWAY_ROUTER.outboundTransferCustomRefund{ value: requiredL1CallValue }(
                    l1Token,
                    L2_REFUND_L2_ADDRESS,
                    to,
                    amount,
                    RELAY_TOKENS_L2_GAS_LIMIT,
                    L2_GAS_PRICE,
                    data
                );
            }
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }

    /**
     * @notice Returns required amount of ETH to send a message via the Inbox.
     * @param l2GasLimit L2 gas limit for the message.
     * @return amount of ETH that this contract needs to hold in order for relayMessage to succeed.
     */
    function getL1CallValue(uint32 l2GasLimit) public pure returns (uint256) {
        return L2_MAX_SUBMISSION_COST + L2_GAS_PRICE * l2GasLimit;
    }

    function _contractHasSufficientEthBalance(uint32 l2GasLimit) internal view returns (uint256) {
        uint256 requiredL1CallValue = getL1CallValue(l2GasLimit);
        require(address(this).balance >= requiredL1CallValue, "Insufficient ETH balance");
        return requiredL1CallValue;
    }
}
