// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ArbitrumForwarderInterface, ArbitrumInboxLike, ArbitrumERC20GatewayLike } from "./interfaces/ArbitrumForwarderInterface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";
import { CircleCCTPAdapter, CircleDomainIds } from "../libraries/CircleCCTPAdapter.sol";

/**
 * @notice Contract containing logic to send messages from L2 to Arbitrum-like L3s.
 * @notice This contract is for interfacing with Arbitrum-like bridges that use the same
 * native token on L3 as the native token on L2.
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_L2_Forwarder is ArbitrumForwarderInterface, CircleCCTPAdapter {
    using SafeERC20 for IERC20;

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == _applyL1ToL2Alias(crossDomainAdmin), "ONLY_CROSS_DOMAIN_ADMIN");
        _;
    }

    /**
     * @notice Constructs new L2 forwarder.
     * @param _l2ArbitrumInbox Inbox helper contract to send messages to Arbitrum.
     * @param _l2ERC20GatewayRouter ERC20 gateway router contract to send tokens to Arbitrum.
     * @param _l3RefundL3Address L3 address to receive gas refunds on after a message is relayed.
     * @param _l2Usdc Native USDC address on L2.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     */
    constructor(
        ArbitrumInboxLike _l2ArbitrumInbox,
        ArbitrumERC20GatewayLike _l2ERC20GatewayRouter,
        address _l3RefundL3Address,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint256 _l3MaxSubmissionCost,
        address _l3SpokePool,
        address _crossDomainAdmin
    )
        ArbitrumForwarderInterface(
            _l2ArbitrumInbox,
            _l2ERC20GatewayRouter,
            _l3RefundL3Address,
            _l3MaxSubmissionCost,
            _l3SpokePool,
            _crossDomainAdmin
        )
        CircleCCTPAdapter(_l2Usdc, _cctpTokenMessenger, CircleDomainIds.UNINITIALIZED)
    {}

    /**
     * @notice Bridge tokens to Arbitrum-like L3.
     * @notice This contract must hold at least getL1CallValue() amount of ETH to send a message via the Inbox
     * successfully, or the message will get stuck.
     * @notice This function will always bridge tokens to the L3 spoke pool.
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
            uint256 requiredL2CallValue = _contractHasSufficientEthBalance(RELAY_TOKENS_L3_GAS_LIMIT);

            // Approve the gateway, not the router, to spend the contract's balance. The gateway, which is different
            // per L1 token, will temporarily escrow the tokens to be bridged and pull them from this contract.
            address erc20Gateway = L2_ERC20_GATEWAY_ROUTER.getGateway(l2Token);
            IERC20(l2Token).safeIncreaseAllowance(erc20Gateway, amount);
            // `outboundTransfer` expects that the caller includes a bytes message as the last param that includes the
            // maxSubmissionCost to use when creating an L3 retryable ticket: https://github.com/OffchainLabs/arbitrum/blob/e98d14873dd77513b569771f47b5e05b72402c5e/packages/arb-bridge-peripherals/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol#L232
            bytes memory data = abi.encode(L3_MAX_SUBMISSION_COST, "");

            L2_ERC20_GATEWAY_ROUTER.outboundTransferCustomRefund{ value: requiredL2CallValue }(
                l2Token,
                L3_REFUND_L3_ADDRESS,
                L3_SPOKE_POOL,
                amount,
                RELAY_TOKENS_L3_GAS_LIMIT,
                L3_GAS_PRICE,
                data
            );
        }
        emit TokensForwarded(l2Token, amount);
    }

    /**
     * @notice Send cross-chain message to target on Arbitrum-like L3.
     * @notice This contract must hold at least getL2CallValue() amount of ETH to send a message via the Inbox
     * successfully, or the message will get stuck.
     * @param target Contract on Arbitrum that will receive message.
     * @param message Data to send to target.
     */
    function _relayMessage(address target, bytes memory message) internal override {
        uint256 requiredL2CallValue = _contractHasSufficientEthBalance(RELAY_MESSAGE_L3_GAS_LIMIT);

        L2_INBOX.createRetryableTicket{ value: requiredL2CallValue }(
            L3_SPOKE_POOL, // destAddr destination L3 contract address
            L3_CALL_VALUE, // l3CallValue call value for retryable L3 message
            L3_MAX_SUBMISSION_COST, // maxSubmissionCost Max gas deducted from user's L3 balance to cover base fee
            L3_REFUND_L3_ADDRESS, // excessFeeRefundAddress maxgas * gasprice - execution cost gets credited here on L3
            L3_REFUND_L3_ADDRESS, // callValueRefundAddress l3Callvalue gets credited here on L3 if retryable txn times out or gets cancelled
            RELAY_MESSAGE_L3_GAS_LIMIT, // maxGas Max gas deducted from user's L3 balance to cover L3 execution
            L3_GAS_PRICE, // gasPriceBid price bid for L3 execution
            message // data ABI encoded data of L3 message
        );

        emit MessageForwarded(target, message);
    }

    function _requireAdminSender() internal virtual override onlyFromCrossDomainAdmin {}

    function _contractHasSufficientEthBalance(uint32 l3GasLimit) internal view returns (uint256) {
        uint256 requiredL2CallValue = getL2CallValue(l3GasLimit);
        require(address(this).balance >= requiredL2CallValue, "Insufficient ETH balance");
        return requiredL2CallValue;
    }

    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        // Allows overflows as explained above.
        unchecked {
            l2Address = address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
        }
    }
}
