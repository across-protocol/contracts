// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";
import { CircleCCTPAdapter, CircleDomainIds } from "../libraries/CircleCCTPAdapter.sol";
import { ArbitrumInboxLike, ArbitrumL1ERC20GatewayLike } from "../interfaces/ArbitrumBridgeInterfaces.sol";
import { ForwarderBase } from "./ForwarderBase.sol";
import { Arbitrum_AdapterBase } from "./Arbitrum_AdapterBase.sol";
import { AddressUtils } from "../libraries/AddressUtils.sol";

/**
 * @notice Contract containing logic to send messages from L2 to AVM L3s.
 * @notice This contract is for interfacing with AVM bridges that use the same
 * native token on L3 as the native token on L2.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_L2Adapter is ForwarderBase, Arbitrum_AdapterBase {
    using SafeERC20 for IERC20;

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == AddressUtils._applyL1ToL2Alias(crossDomainAdmin), "ONLY_CROSS_DOMAIN_ADMIN");
        _;
    }

    /**
     * @notice Constructs new L2 forwarder.
     * @dev We normally cannot define a constructor for proxies, but this is an exception since all
     * arguments are stored as immutable variables (and thus kept in contract bytecode).
     * @param _l2ArbitrumInbox Inbox helper contract to send messages to the AVM L3.
     * @param _l2ERC20GatewayRouter ERC20 gateway router contract to send tokens to the L3.
     * @param _l3RefundL3Address L3 address to receive gas refunds on after a message is relayed.
     * @param _l2Usdc Native USDC address on L2.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     * @param _circleDomainId Circle CCTP domain ID for the target network (uint32.max) for uninitialized.
     * @param _l3MaxSubmissionCost maximum amount of ETH to send with a transaction for it to execute on L2.
     * @param _l3GasPrice gas price bid for a message to be executed on L2.
     */
    constructor(
        ArbitrumInboxLike _l2ArbitrumInbox,
        ArbitrumL1ERC20GatewayLike _l2ERC20GatewayRouter,
        address _l3RefundL3Address,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _circleDomainId,
        uint256 _l3MaxSubmissionCost,
        uint256 _l3GasPrice
    )
        Arbitrum_AdapterBase(
            _l2ArbitrumInbox,
            _l2ERC20GatewayRouter,
            _l3RefundL3Address,
            _l2Usdc,
            _cctpTokenMessenger,
            _circleDomainId,
            _l3MaxSubmissionCost,
            _l3GasPrice
        )
        ForwarderBase()
    {}

    /**
     * @notice Bridge tokens to L3.
     * @notice This contract must hold at least getL1CallValue() amount of ETH to send a message via the Inbox
     * successfully, or the message will get stuck.
     * @notice This function will always bridge tokens to the L3 spoke pool.
     * @param l2Token L2 token to send.
     * @param amount Amount of L2 tokens to deposit and L3 tokens to receive.
     */
    function relayTokens(
        address l2Token,
        address,
        uint256 amount
    ) external payable override {
        _relayTokens(l2Token, address(0), amount, l3SpokePool);
        emit TokensForwarded(l2Token, amount);
    }

    /**
     * @notice Send cross-chain message to target on L3.
     * @notice This contract must hold at least getL2CallValue() amount of ETH to send a message via the Inbox
     * successfully, or the message will get stuck.
     * @param target Contract on L3 that will receive message.
     * @param message Data to send to target.
     */
    function _relayL3Message(address target, bytes memory message) internal override {
        _relayMessage(target, message);
        emit MessageForwarded(target, message);
    }

    function _requireAdminSender() internal virtual override onlyFromCrossDomainAdmin {}
}
