// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Arbitrum_AdapterBase } from "./Arbitrum_AdapterBase.sol";
import { ITokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";
import { ArbitrumInboxLike, ArbitrumL1ERC20GatewayLike } from "../interfaces/ArbitrumBridgeInterfaces.sol";

/**
 * @notice Contract containing logic to send messages from L1 to Arbitrum.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_Adapter is AdapterInterface, Arbitrum_AdapterBase {
    using SafeERC20 for IERC20;

    /**
     * @notice Constructs new Adapter.
     * @param _l1ArbitrumInbox Inbox helper contract to send messages to Arbitrum.
     * @param _l1ERC20GatewayRouter ERC20 gateway router contract to send tokens to Arbitrum.
     * @param _l2RefundL2Address L2 address to receive gas refunds on after a message is relayed.
     * @param _l1Usdc USDC address on L1.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     * @param _circleDomainId Circle CCTP domain ID for the target network (3 for Arbitrum).
     * @param _l2MaxSubmissionCost maximum amount of ETH to send with a transaction for it to execute on L2.
     * @param _l2GasPrice gas price bid for a message to be executed on L2.
     */
    constructor(
        ArbitrumInboxLike _l1ArbitrumInbox,
        ArbitrumL1ERC20GatewayLike _l1ERC20GatewayRouter,
        address _l2RefundL2Address,
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _circleDomainId,
        uint256 _l2MaxSubmissionCost,
        uint256 _l2GasPrice
    )
        Arbitrum_AdapterBase(
            _l1ArbitrumInbox,
            _l1ERC20GatewayRouter,
            _l2RefundL2Address,
            _l1Usdc,
            _cctpTokenMessenger,
            _circleDomainId,
            _l2MaxSubmissionCost,
            _l2GasPrice
        )
    {}

    /**
     * @notice Send cross-chain message to target on Arbitrum.
     * @notice This contract must hold at least getL1CallValue() amount of ETH to send a message via the Inbox
     * successfully, or the message will get stuck.
     * @param target Contract on Arbitrum that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        _relayMessage(target, message);
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
        _relayTokens(l1Token, l2Token, amount, to);
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
