// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITokenMessenger as ICCTPTokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";
import { CircleCCTPAdapter, CircleDomainIds } from "../libraries/CircleCCTPAdapter.sol";

interface FunderInterface {
    function withdraw(IERC20 token, uint256 amount) external;
}

/**
 * @title Staging ground for incoming and outgoing messages
 * @notice Unlike the standard Eth bridge, native token bridge escrows the custom ERC20 token which is
 * used as native currency on L2.
 * @dev Fees are paid in this token. There are certain restrictions on the native token:
 *       - The token can't be rebasing or have a transfer fee
 *       - The token must only be transferrable via a call to the token address itself
 *       - The token must only be able to set allowance via a call to the token address itself
 *       - The token must not have a callback on transfer, and more generally a user must not be able to make a transfer to themselves revert
 *       - The token must have a max of 2^256 - 1 wei total supply unscaled
 *       - The token must have a max of 2^256 - 1 wei total supply when scaled to 18 decimals
 */
interface ArbitrumL1ERC20Bridge {
    /**
     * @notice Returns token that is escrowed in bridge on L1 side and minted on L2 as native currency.
     * @dev This function doesn't exist on the generic Bridge interface.
     * @return address of the native token.
     */
    function nativeToken() external view returns (address);

    /**
     * @dev number of decimals used by the native token
     *      This is set on bridge initialization using nativeToken.decimals()
     *      If the token does not have decimals() method, we assume it have 0 decimals
     */
    function nativeTokenDecimals() external view returns (uint8);
}

/**
 * @title Inbox for user and contract originated messages
 * @notice Messages created via this inbox are enqueued in the delayed accumulator
 * to await inclusion in the SequencerInbox
 */
interface ArbitrumL1InboxLike {
    /**
     * @dev we only use this function to check the native token used by the bridge, so we hardcode the interface
     * to return an ArbitrumL1ERC20Bridge instead of a more generic Bridge interface.
     * @return address of the bridge.
     */
    function bridge() external view returns (ArbitrumL1ERC20Bridge);

    /**
     * @notice Put a message in the L2 inbox that can be reexecuted for some fixed amount of time if it reverts
     * @notice Overloads the `createRetryableTicket` function but is not payable, and should only be called when paying
     * for L1 to L2 message using a custom gas token.
     * @dev all tokenTotalFeeAmount will be deposited to callValueRefundAddress on L2
     * @dev Gas limit and maxFeePerGas should not be set to 1 as that is used to trigger the RetryableData error
     * @dev In case of native token having non-18 decimals: tokenTotalFeeAmount is denominated in native token's decimals. All other value params - l2CallValue, maxSubmissionCost and maxFeePerGas are denominated in child chain's native 18 decimals.
     * @param to destination L2 contract address
     * @param l2CallValue call value for retryable L2 message
     * @param maxSubmissionCost Max gas deducted from user's L2 balance to cover base submission fee
     * @param excessFeeRefundAddress the address which receives the difference between execution fee paid and the actual execution cost. In case this address is a contract, funds will be received in its alias on L2.
     * @param callValueRefundAddress l2Callvalue gets credited here on L2 if retryable txn times out or gets cancelled. In case this address is a contract, funds will be received in its alias on L2.
     * @param gasLimit Max gas deducted from user's L2 balance to cover L2 execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param maxFeePerGas price bid for L2 execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param tokenTotalFeeAmount amount of fees to be deposited in native token to cover for retryable ticket cost
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
        uint256 tokenTotalFeeAmount,
        bytes calldata data
    ) external returns (uint256);
}

/**
 * @notice Layer 1 Gateway contract for bridging standard ERC20s to Arbitrum.
 */
interface ArbitrumL1ERC20GatewayLike {
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
 * @dev This contract is very similar to Arbitrum_Adapter but it allows the caller to pay for retryable ticket
 * submission fees using a custom gas token. This is required to support certain Arbitrum orbit L2s and L3s.
 * @custom:security-contact bugs@across.to
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

    uint256 public constant L2_CALL_VALUE = 0;

    uint32 public constant RELAY_TOKENS_L2_GAS_LIMIT = 300_000;
    uint32 public constant RELAY_MESSAGE_L2_GAS_LIMIT = 2_000_000;

    // This address on L2 receives extra gas token that is left over after relaying a message via the inbox.
    address public immutable L2_REFUND_L2_ADDRESS;

    ArbitrumL1InboxLike public immutable L1_INBOX;

    ArbitrumL1ERC20GatewayLike public immutable L1_ERC20_GATEWAY_ROUTER;

    // This token is used to pay for l1 to l2 messages if its configured by an Arbitrum orbit chain.
    IERC20 public immutable CUSTOM_GAS_TOKEN;

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
