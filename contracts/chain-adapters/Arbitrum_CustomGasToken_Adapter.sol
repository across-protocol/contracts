// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITokenMessenger as ICCTPTokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";
import { CircleCCTPAdapter, CircleDomainIds } from "../libraries/CircleCCTPAdapter.sol";
import { ArbitrumERC20Bridge as ArbitrumL1ERC20Bridge, ArbitrumCustomGasTokenInbox as ArbitrumL1InboxLike, ArbitrumL1ERC20GatewayLike } from "../interfaces/ArbitrumBridgeInterfaces.sol";

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
 * @notice Contract containing logic to send messages from L1 to Arbitrum.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @dev This contract is very similar to Arbitrum_Adapter but it allows the caller to pay for submission
 * fees using a custom gas token. This is required to support certain Arbitrum orbit L2s and L3s.
 * @dev https://docs.arbitrum.io/launch-orbit-chain/how-tos/use-a-custom-gas-token
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_CustomGasToken_Adapter is AdapterInterface, CircleCCTPAdapter {
    using SafeERC20 for IERC20;

    // Amount of gas token allocated to pay for the base submission fee. The base submission fee is a parameter unique to
    // retryable transactions; the user is charged the base submission fee to cover the storage costs of keeping their
    // ticket’s calldata in the retry buffer. (current base submission fee is queryable via
    // ArbRetryableTx.getSubmissionPrice). ArbRetryableTicket precompile interface exists at L2 address
    // 0x000000000000000000000000000000000000006E.
    // The Arbitrum Inbox requires that this uses 18 decimal precision.
    uint256 public immutable L2_MAX_SUBMISSION_COST;

    // L2 Gas price bid for immediate L2 execution attempt (queryable via standard eth*gasPrice RPC)
    // The Arbitrum Inbox requires that this is specified in gWei (e.g. 1e9 = 1 gWei)
    uint256 public immutable L2_GAS_PRICE;

    // Native token expected to be sent in L2 message. Should be 0 for all use cases of this constant, which
    // includes sending messages from L1 to L2 and sending Custom gas token ERC20's, which won't be the native token
    // on the L2 by definition.
    uint256 public constant L2_CALL_VALUE = 0;

    // Gas limit for L2 execution of a cross chain token transfer sent via the inbox.
    uint32 public constant RELAY_TOKENS_L2_GAS_LIMIT = 300_000;
    // Gas limit for L2 execution of a message sent via the inbox.
    uint32 public constant RELAY_MESSAGE_L2_GAS_LIMIT = 2_000_000;

    // This address on L2 receives extra gas token that is left over after relaying a message via the inbox.
    address public immutable L2_REFUND_L2_ADDRESS;

    // Inbox system contract to send messages to Arbitrum. Token bridges use this to send tokens to L2.
    // https://github.com/OffchainLabs/nitro-contracts/blob/f7894d3a6d4035ba60f51a7f1334f0f2d4f02dce/src/bridge/Inbox.sol
    ArbitrumL1InboxLike public immutable L1_INBOX;

    // Router contract to send tokens to Arbitrum. Routes to correct gateway to bridge tokens. Internally this
    // contract calls the Inbox.
    // Generic gateway: https://github.com/OffchainLabs/token-bridge-contracts/blob/main/contracts/tokenbridge/ethereum/gateway/L1ArbitrumGateway.sol
    // Gateway used for communicating with chains that use custom gas tokens:
    // https://github.com/OffchainLabs/token-bridge-contracts/blob/main/contracts/tokenbridge/ethereum/gateway/L1ERC20Gateway.sol
    ArbitrumL1ERC20GatewayLike public immutable L1_ERC20_GATEWAY_ROUTER;

    // This token is used to pay for l1 to l2 messages if its configured by an Arbitrum orbit chain.
    IERC20 public immutable CUSTOM_GAS_TOKEN;

    // Contract that funds Inbox cross chain messages with the custom gas token.
    FunderInterface public immutable CUSTOM_GAS_TOKEN_FUNDER;

    error InvalidCustomGasToken();
    error InsufficientCustomGasToken();

    /**
     * @notice Constructs new Adapter.
     * @param _l1ArbitrumInbox Inbox helper contract to send messages to Arbitrum.
     * @param _l1ERC20GatewayRouter ERC20 gateway router contract to send tokens to Arbitrum.
     * @param _l2RefundL2Address L2 address to receive gas refunds on after a message is relayed.
     * @param _l1Usdc USDC address on L1.
     * @param _l2MaxSubmissionCost Max gas deducted from user's L2 balance to cover base fee.
     * @param _l2GasPrice Gas price bid for L2 execution. Should be set conservatively high to avoid stuck messages.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     * @param _customGasTokenFunder Contract that funds the custom gas token.
     * @param _l2MaxSubmissionCost Amount of gas token allocated to pay for the base submission fee. The base
     * submission fee is a parameter unique to Arbitrum retryable transactions. This value is hardcoded
     * and used for all messages sent by this adapter.
     */
    constructor(
        ArbitrumL1InboxLike _l1ArbitrumInbox,
        ArbitrumL1ERC20GatewayLike _l1ERC20GatewayRouter,
        address _l2RefundL2Address,
        IERC20 _l1Usdc,
        ICCTPTokenMessenger _cctpTokenMessenger,
        FunderInterface _customGasTokenFunder,
        uint256 _l2MaxSubmissionCost,
        uint256 _l2GasPrice
    ) CircleCCTPAdapter(_l1Usdc, _cctpTokenMessenger, CircleDomainIds.Arbitrum) {
        L1_INBOX = _l1ArbitrumInbox;
        L1_ERC20_GATEWAY_ROUTER = _l1ERC20GatewayRouter;
        L2_REFUND_L2_ADDRESS = _l2RefundL2Address;
        CUSTOM_GAS_TOKEN = IERC20(L1_INBOX.bridge().nativeToken());
        if (address(CUSTOM_GAS_TOKEN) == address(0)) revert InvalidCustomGasToken();
        L2_MAX_SUBMISSION_COST = _l2MaxSubmissionCost;
        L2_GAS_PRICE = _l2GasPrice;
        CUSTOM_GAS_TOKEN_FUNDER = _customGasTokenFunder;
    }

    /**
     * @notice Send cross-chain message to target on Arbitrum.
     * @notice This contract must hold at least getL1CallValue() amount of the custom gas token
     * to send a message via the Inbox successfully, or the message will get stuck.
     * @param target Contract on Arbitrum that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        uint256 requiredL1TokenTotalFeeAmount = _pullCustomGas(RELAY_MESSAGE_L2_GAS_LIMIT);
        CUSTOM_GAS_TOKEN.safeIncreaseAllowance(address(L1_INBOX), requiredL1TokenTotalFeeAmount);
        L1_INBOX.createRetryableTicket(
            target, // destAddr destination L2 contract address
            L2_CALL_VALUE, // l2CallValue call value for retryable L2 message
            L2_MAX_SUBMISSION_COST, // maxSubmissionCost Max gas deducted from user's L2 balance to cover base fee
            L2_REFUND_L2_ADDRESS, // excessFeeRefundAddress maxgas * gasprice - execution cost gets credited here on L2
            L2_REFUND_L2_ADDRESS, // callValueRefundAddress l2Callvalue gets credited here on L2 if retryable txn times out or gets cancelled
            RELAY_MESSAGE_L2_GAS_LIMIT, // maxGas Max gas deducted from user's L2 balance to cover L2 execution
            L2_GAS_PRICE, // gasPriceBid price bid for L2 execution
            requiredL1TokenTotalFeeAmount, // tokenTotalFeeAmount amount of fees to be deposited in native token.
            // This should be in the precision of the custom gas token.
            message // data ABI encoded data of L2 message
        );
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Arbitrum.
     * @notice This contract must hold at least getL1CallValue() amount of ETH or custom gas token
     * to send a message via the Inbox successfully, or the message will get stuck.
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
            address erc20Gateway = L1_ERC20_GATEWAY_ROUTER.getGateway(l1Token);

            // If custom gas token, call special functions that handle paying with custom gas tokens.
            uint256 requiredL1TokenTotalFeeAmount = _pullCustomGas(RELAY_MESSAGE_L2_GAS_LIMIT);

            // Must use Inbox to bridge custom gas token.
            // Source: https://github.com/OffchainLabs/token-bridge-contracts/blob/5bdf33259d2d9ae52ddc69bc5a9cbc558c4c40c7/contracts/tokenbridge/ethereum/gateway/L1OrbitERC20Gateway.sol#L33
            if (l1Token == address(CUSTOM_GAS_TOKEN)) {
                // amount and requiredL1TokenTotalFeeAmount are in the precision of the custom gas token.
                uint256 amountToBridge = amount + requiredL1TokenTotalFeeAmount;
                CUSTOM_GAS_TOKEN.safeIncreaseAllowance(address(L1_INBOX), amountToBridge);
                L1_INBOX.createRetryableTicket(
                    to, // destAddr destination L2 contract address
                    L2_CALL_VALUE, // l2CallValue call value for retryable L2 message
                    L2_MAX_SUBMISSION_COST, // maxSubmissionCost Max gas deducted from user's L2 balance to cover base fee
                    L2_REFUND_L2_ADDRESS, // excessFeeRefundAddress maxgas * gasprice - execution cost gets credited here on L2
                    L2_REFUND_L2_ADDRESS, // callValueRefundAddress l2Callvalue gets credited here on L2 if retryable txn times out or gets cancelled
                    RELAY_MESSAGE_L2_GAS_LIMIT, // maxGas Max gas deducted from user's L2 balance to cover L2 execution
                    L2_GAS_PRICE, // gasPriceBid price bid for L2 execution
                    amountToBridge, // tokenTotalFeeAmount amount of fees to be deposited in native token.
                    "0x" // data ABI encoded data of L2 message
                );
            } else {
                IERC20(l1Token).safeIncreaseAllowance(erc20Gateway, amount);
                CUSTOM_GAS_TOKEN.safeIncreaseAllowance(erc20Gateway, requiredL1TokenTotalFeeAmount);

                // To pay for gateway outbound transfer with custom gas token, encode the tokenTotalFeeAmount in the data field:
                // The data format should be (uint256 maxSubmissionCost, bytes extraData, uint256 tokenTotalFeeAmount).
                // Source: https://github.com/OffchainLabs/token-bridge-contracts/blob/5bdf33259d2d9ae52ddc69bc5a9cbc558c4c40c7/contracts/tokenbridge/ethereum/gateway/L1OrbitERC20Gateway.sol#L57
                bytes memory data = abi.encode(L2_MAX_SUBMISSION_COST, "", requiredL1TokenTotalFeeAmount);
                L1_ERC20_GATEWAY_ROUTER.outboundTransferCustomRefund(
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
     * @notice Returns required amount of gas token to send a message via the Inbox.
     * @dev Should return a value in the same precision as the gas token's precision.
     * @param l2GasLimit L2 gas limit for the message.
     * @return amount of gas token that this contract needs to hold in order for relayMessage to succeed.
     */
    function getL1CallValue(uint32 l2GasLimit) public view returns (uint256) {
        return _from18ToNativeDecimals(L2_MAX_SUBMISSION_COST + L2_GAS_PRICE * l2GasLimit);
    }

    function _pullCustomGas(uint32 l2GasLimit) internal returns (uint256) {
        uint256 requiredL1CallValue = getL1CallValue(l2GasLimit);
        CUSTOM_GAS_TOKEN_FUNDER.withdraw(CUSTOM_GAS_TOKEN, requiredL1CallValue);
        if (CUSTOM_GAS_TOKEN.balanceOf(address(this)) < requiredL1CallValue) revert InsufficientCustomGasToken();
        return requiredL1CallValue;
    }

    function _from18ToNativeDecimals(uint256 amount) internal view returns (uint256) {
        uint8 nativeTokenDecimals = L1_INBOX.bridge().nativeTokenDecimals();
        if (nativeTokenDecimals == 18) {
            return amount;
        } else if (nativeTokenDecimals < 18) {
            // Round up the division result so that the L1 call value is always sufficient to cover the submission fee.
            uint256 reductionFactor = 10**(18 - nativeTokenDecimals);
            uint256 divFloor = amount / reductionFactor;
            uint256 mod = amount % reductionFactor;
            if (mod != 0) {
                return divFloor + 1;
            } else {
                return divFloor;
            }
        } else {
            return amount * 10**(nativeTokenDecimals - 18);
        }
    }
}
