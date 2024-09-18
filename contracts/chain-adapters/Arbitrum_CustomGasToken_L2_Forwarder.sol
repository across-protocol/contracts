// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ArbitrumForwarderInterface, ArbitrumERC20Bridge, ArbitrumInboxLike, ArbitrumERC20GatewayLike, ArbitrumERC20Bridge } from "./interfaces/ArbitrumForwarderInterface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CircleCCTPAdapter, CircleDomainIds } from "../libraries/CircleCCTPAdapter.sol";
import { ITokenMessenger as ICCTPTokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";

/**
 * @notice Interface for funder contract that this contract pulls from to pay for relayMessage()/relayTokens()
 * fees using a custom gas token.
 */
interface FunderInterface {
    /**
     * @notice Withdraws amount of token from funder contract to the caller.
     * @dev Can only be called by owner of Funder contract, which therefore must be
     * this contract.
     * @param token Token to withdraw.
     * @param amount Amount to withdraw.
     */
    function withdraw(IERC20 token, uint256 amount) external;
}

/**
 * @notice Contract containing logic to send messages from Arbitrum to an Arbitrum-like L3.
 * @dev This contract is very similar to Arbitrum_CustomGasToken_Adapter. It is meant to bridge
 * tokens and send messages over a bridge which uses a custom gas token, except this contract assumes
 * it is deployed on Arbitrum.
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_CustomGasToken_L2_Forwarder is ArbitrumForwarderInterface, CircleCCTPAdapter {
    using SafeERC20 for IERC20;

    // This token is used to pay for l2 to l3 messages if its configured by an Arbitrum orbit chain.
    IERC20 public immutable CUSTOM_GAS_TOKEN;

    // Contract that funds Inbox cross chain messages with the custom gas token.
    FunderInterface public immutable CUSTOM_GAS_TOKEN_FUNDER;

    error InvalidCustomGasToken();
    error InsufficientCustomGasToken();

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == _applyL1ToL2Alias(crossDomainAdmin), "ONLY_CROSS_DOMAIN_ADMIN");
        _;
    }

    /**
     * @notice Constructs new L2 Forwarder.
     * @param _l2ArbitrumInbox Inbox helper contract to send messages to Arbitrum.
     * @param _l2ERC20GatewayRouter ERC20 gateway router contract to send tokens to Arbitrum.
     * @param _l3RefundL3Address L3 address to receive gas refunds on after a message is relayed.
     * @param _l2Usdc Native USDC address on L2.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     * @param _customGasTokenFunder Contract that funds the custom gas token.
     * @param _l3MaxSubmissionCost Amount of gas token allocated to pay for the base submission fee. The base
     * submission fee is a parameter unique to Arbitrum retryable transactions. This value is hardcoded
     * and used for all messages sent by this adapter.
     */
    constructor(
        ArbitrumInboxLike _l2ArbitrumInbox,
        ArbitrumERC20GatewayLike _l2ERC20GatewayRouter,
        address _l3RefundL3Address,
        IERC20 _l2Usdc,
        ICCTPTokenMessenger _cctpTokenMessenger,
        FunderInterface _customGasTokenFunder,
        uint256 _l3MaxSubmissionCost,
        address _l3SpokePool,
        address _crossDomainAdmin
    )
        CircleCCTPAdapter(_l2Usdc, _cctpTokenMessenger, CircleDomainIds.UNINITIALIZED)
        ArbitrumForwarderInterface(
            _l2ArbitrumInbox,
            _l2ERC20GatewayRouter,
            _l3RefundL3Address,
            _l3MaxSubmissionCost,
            _l3SpokePool,
            _crossDomainAdmin
        )
    {
        CUSTOM_GAS_TOKEN = IERC20(L2_INBOX.bridge().nativeToken());
        if (address(CUSTOM_GAS_TOKEN) == address(0)) revert InvalidCustomGasToken();
        CUSTOM_GAS_TOKEN_FUNDER = _customGasTokenFunder;
    }

    /**
     * @notice Bridge tokens to Arbitrum-like L3.
     * @notice This contract must hold at least getL2CallValue() amount of ETH or custom gas token
     * to send a message via the Inbox successfully, or the message will get stuck.
     * @param l2Token L2 token to send.
     * @param amount Amount of L2 tokens to deposit and L3 tokens to receive.
     */
    function relayTokens(address l2Token, uint256 amount) external payable override {
        // Check if this token is USDC, which requires a custom bridge via CCTP.
        if (_isCCTPEnabled() && l2Token == address(usdcToken)) {
            _transferUsdc(L3_SPOKE_POOL, amount);
        }
        // If not, we can use the Arbitrum gateway
        else {
            address erc20Gateway = L2_ERC20_GATEWAY_ROUTER.getGateway(l2Token);

            // If custom gas token, call special functions that handle paying with custom gas tokens.
            uint256 requiredL2TokenTotalFeeAmount = _pullCustomGas(RELAY_MESSAGE_L3_GAS_LIMIT);

            // Must use Inbox to bridge custom gas token.
            // Source: https://github.com/OffchainLabs/token-bridge-contracts/blob/5bdf33259d2d9ae52ddc69bc5a9cbc558c4c40c7/contracts/tokenbridge/ethereum/gateway/L1OrbitERC20Gateway.sol#L33
            if (l2Token == address(CUSTOM_GAS_TOKEN)) {
                uint256 amountToBridge = amount + requiredL2TokenTotalFeeAmount;
                CUSTOM_GAS_TOKEN.safeIncreaseAllowance(address(L2_INBOX), amountToBridge);
                L2_INBOX.createRetryableTicket(
                    L3_SPOKE_POOL, // destAddr destination L3 contract address (the spoke pool)
                    L3_CALL_VALUE, // l3CallValue call value for retryable L3 message
                    L3_MAX_SUBMISSION_COST, // maxSubmissionCost Max gas deducted from user's L3 balance to cover base fee
                    L3_REFUND_L3_ADDRESS, // excessFeeRefundAddress maxgas * gasprice - execution cost gets credited here on L3
                    L3_REFUND_L3_ADDRESS, // callValueRefundAddress l2Callvalue gets credited here on L3 if retryable txn times out or gets cancelled
                    RELAY_MESSAGE_L3_GAS_LIMIT, // maxGas Max gas deducted from user's L3 balance to cover L3 execution
                    L3_GAS_PRICE, // gasPriceBid price bid for L3 execution
                    amountToBridge, // tokenTotalFeeAmount amount of fees to be deposited in native token.
                    "0x" // data ABI encoded data of L3 message
                );
            } else {
                IERC20(l2Token).safeIncreaseAllowance(erc20Gateway, amount);
                CUSTOM_GAS_TOKEN.safeIncreaseAllowance(erc20Gateway, requiredL2TokenTotalFeeAmount);

                // To pay for gateway outbound transfer with custom gas token, encode the tokenTotalFeeAmount in the data field:
                // The data format should be (uint256 maxSubmissionCost, bytes extraData, uint256 tokenTotalFeeAmount).
                // Source: https://github.com/OffchainLabs/token-bridge-contracts/blob/5bdf33259d2d9ae52ddc69bc5a9cbc558c4c40c7/contracts/tokenbridge/ethereum/gateway/L1OrbitERC20Gateway.sol#L57
                bytes memory data = abi.encode(L3_MAX_SUBMISSION_COST, "", requiredL2TokenTotalFeeAmount);
                L2_ERC20_GATEWAY_ROUTER.outboundTransferCustomRefund(
                    l2Token,
                    L3_REFUND_L3_ADDRESS,
                    L3_SPOKE_POOL,
                    amount,
                    RELAY_TOKENS_L3_GAS_LIMIT,
                    L3_GAS_PRICE,
                    data
                );
            }
        }
        emit TokensForwarded(l2Token, amount);
    }

    /**
     * @notice Send cross-chain message to target on Arbitrum-like L3.
     * @notice This contract must hold at least getL2CallValue() amount of the custom gas token
     * to send a message via the Inbox successfully, or the message will get stuck.
     * @param target Contract on Arbitrum-like L3 that will receive message.
     * @param message Data to send to target.
     */
    function _relayMessage(address target, bytes memory message) internal override {
        uint256 requiredL2TokenTotalFeeAmount = _pullCustomGas(RELAY_MESSAGE_L3_GAS_LIMIT);
        CUSTOM_GAS_TOKEN.safeIncreaseAllowance(address(L2_INBOX), requiredL2TokenTotalFeeAmount);
        L2_INBOX.createRetryableTicket(
            target, // destAddr destination L3 contract address
            L3_CALL_VALUE, // l3CallValue call value for retryable L3 message
            L3_MAX_SUBMISSION_COST, // maxSubmissionCost Max gas deducted from user's L3 balance to cover base fee
            L3_REFUND_L3_ADDRESS, // excessFeeRefundAddress maxgas * gasprice - execution cost gets credited here on L3
            L3_REFUND_L3_ADDRESS, // callValueRefundAddress l3Callvalue gets credited here on L3 if retryable txn times out or gets cancelled
            RELAY_MESSAGE_L3_GAS_LIMIT, // maxGas Max gas deducted from user's L3 balance to cover L3 execution
            L3_GAS_PRICE, // gasPriceBid price bid for L3 execution
            requiredL2TokenTotalFeeAmount, // tokenTotalFeeAmount amount of fees to be deposited in native token.
            message // data ABI encoded data of L3 message
        );
        emit MessageForwarded(target, message);
    }

    function _requireAdminSender() internal virtual override onlyFromCrossDomainAdmin {}

    function _pullCustomGas(uint32 l3GasLimit) internal returns (uint256) {
        uint256 requiredL2CallValue = getL2CallValue(l3GasLimit);
        CUSTOM_GAS_TOKEN_FUNDER.withdraw(CUSTOM_GAS_TOKEN, requiredL2CallValue);
        if (CUSTOM_GAS_TOKEN.balanceOf(address(this)) < requiredL2CallValue) revert InsufficientCustomGasToken();
        return requiredL2CallValue;
    }

    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        // Allows overflows as explained above.
        unchecked {
            l2Address = address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
        }
    }
}
