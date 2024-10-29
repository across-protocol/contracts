// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITokenMessenger as ICCTPTokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";
import { FunderInterface, ArbitrumL1ERC20Bridge, ArbitrumL1InboxLike, ArbitrumL1ERC20GatewayLike, Arbitrum_CustomGasToken_Adapter } from "./Arbitrum_CustomGasToken_Adapter.sol";

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
contract Arbitrum_LegacyCustomGasToken_Adapter is Arbitrum_CustomGasToken_Adapter {
    using SafeERC20 for IERC20;

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
        uint32 _cctpDomainId,
        FunderInterface _customGasTokenFunder,
        uint256 _l2MaxSubmissionCost,
        uint256 _l2GasPrice
    )
        Arbitrum_CustomGasToken_Adapter(
            _l1ArbitrumInbox,
            _l1ERC20GatewayRouter,
            _l2RefundL2Address,
            _l1Usdc,
            _cctpTokenMessenger,
            _cctpDomainId,
            _customGasTokenFunder,
            _l2MaxSubmissionCost,
            _l2GasPrice
        )
    {}

    /**
     * @notice Returns required amount of gas token to send a message via the Inbox.
     * @dev Should return a value in the same precision as the gas token's precision.
     * @param l2GasLimit L2 gas limit for the message.
     * @return amount of gas token that this contract needs to hold in order for relayMessage to succeed.
     */
    function getL1CallValue(uint32 l2GasLimit) public view override returns (uint256) {
        return L2_MAX_SUBMISSION_COST + L2_GAS_PRICE * l2GasLimit;
    }
}
