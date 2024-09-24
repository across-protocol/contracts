// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Arbitrum_CustomGasToken_AdapterBase, FunderInterface } from "./Arbitrum_CustomGasToken_AdapterBase.sol";
import { ArbitrumCustomGasTokenInbox, ArbitrumL1ERC20GatewayLike } from "../interfaces/ArbitrumBridgeInterfaces.sol";
import { ITokenMessenger as ICCTPTokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";

/**
 * @notice Contract containing logic to send messages from L1 to Arbitrum.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @dev This contract is very similar to Arbitrum_Adapter but it allows the caller to pay for submission
 * fees using a custom gas token. This is required to support certain Arbitrum orbit L2s and L3s.
 * @dev https://docs.arbitrum.io/launch-orbit-chain/how-tos/use-a-custom-gas-token
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_CustomGasToken_Adapter is AdapterInterface, Arbitrum_CustomGasToken_AdapterBase {
    using SafeERC20 for IERC20;

    /**
     * @notice Constructs new Adapter.
     * @param _l1ArbitrumInbox Inbox helper contract to send messages to Arbitrum.
     * @param _l1ERC20GatewayRouter ERC20 gateway router contract to send tokens to Arbitrum.
     * @param _l2RefundL2Address L2 address to receive gas refunds on after a message is relayed.
     * @param _l1Usdc USDC address on L1.
     * @param _circleDomainId CCTP domain ID for the target network.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     * @param _customGasTokenFunder Contract that funds the custom gas token.
     * @param _l2MaxSubmissionCost Max gas deducted from user's L2 balance to cover base fee.
     * @param _l2GasPrice Gas price bid for L2 execution. Should be set conservatively high to avoid stuck messages.
     */
    constructor(
        ArbitrumCustomGasTokenInbox _l1ArbitrumInbox,
        ArbitrumL1ERC20GatewayLike _l1ERC20GatewayRouter,
        address _l2RefundL2Address,
        IERC20 _l1Usdc,
        ICCTPTokenMessenger _cctpTokenMessenger,
        uint32 _circleDomainId,
        FunderInterface _customGasTokenFunder,
        uint256 _l2MaxSubmissionCost,
        uint256 _l2GasPrice
    )
        Arbitrum_CustomGasToken_AdapterBase(
            _l1ArbitrumInbox,
            _l1ERC20GatewayRouter,
            _l2RefundL2Address,
            _l1Usdc,
            _cctpTokenMessenger,
            _circleDomainId,
            _customGasTokenFunder,
            _l2MaxSubmissionCost,
            _l2GasPrice
        )
    {}

    /**
     * @notice Send cross-chain message to target on Arbitrum.
     * @notice This contract must hold at least getL1CallValue() amount of the custom gas token
     * to send a message via the Inbox successfully, or the message will get stuck.
     * @param target Contract on Arbitrum that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        _relayMessage(target, message);
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
        _relayTokens(l1Token, l2Token, amount, to);
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
