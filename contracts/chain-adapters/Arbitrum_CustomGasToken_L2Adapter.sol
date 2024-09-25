// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CircleCCTPAdapter, CircleDomainIds } from "../libraries/CircleCCTPAdapter.sol";
import { ITokenMessenger as ICCTPTokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";
import { ArbitrumCustomGasTokenInbox, ArbitrumL1ERC20GatewayLike } from "../interfaces/ArbitrumBridgeInterfaces.sol";
import { ForwarderBase } from "./ForwarderBase.sol";
import { Arbitrum_CustomGasToken_AdapterBase, FunderInterface } from "./Arbitrum_CustomGasToken_AdapterBase.sol";
import { AddressUtils } from "../libraries/AddressUtils.sol";

/**
 * @notice Contract to be deployed on L2 containing logic to send messages from Arbitrum to an AVM L3.
 * @dev This contract is very similar to Arbitrum_CustomGasToken_Adapter. It is meant to bridge
 * tokens and send messages over a bridge which uses a custom gas token, except this contract assumes
 * it is deployed on Arbitrum.
 * @dev This contract sends messages to L3 when the msg.sender is the `crossDomainAdmin` (which should
 * be set to the hub pool). The `crossDomainAdmin` is defined upon initialization.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_CustomGasToken_L2Adapter is Arbitrum_CustomGasToken_AdapterBase, ForwarderBase, AdapterInterface {
    using SafeERC20 for IERC20;

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == AddressUtils._applyL1ToL2Alias(crossDomainAdmin), "ONLY_CROSS_DOMAIN_ADMIN");
        _;
    }

    /**
     * @notice Constructs new L2 Forwarder.
     * @dev We normally cannot define a constructor for proxies, but this is an exception since all
     * arguments are stored as immutable variables (and thus kept in contract bytecode).
     * @param _l2ArbitrumInbox Inbox helper contract to send messages to Arbitrum.
     * @param _l2ERC20GatewayRouter ERC20 gateway router contract to send tokens to Arbitrum.
     * @param _l3RefundL3Address L3 address to receive gas refunds on after a message is relayed.
     * @param _l2Usdc Native USDC address on L2.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     * @param _circleDomainId CCTP domain ID of the target network.
     * @param _customGasTokenFunder Contract that funds the custom gas token.
     * @param _l3MaxSubmissionCost Amount of gas token allocated to pay for the base submission fee. The base
     * submission fee is a parameter unique to Arbitrum retryable transactions. This value is hardcoded
     * and used for all messages sent by this adapter.
     * @param _l3GasPrice Gas price bid for L3 execution. Should be set conservatively high to avoid stuck messages.
     * @dev Both `crossDomainAdmin` and `l3SpokePool` are defined on initialization of the proxy.
     */
    constructor(
        ArbitrumCustomGasTokenInbox _l2ArbitrumInbox,
        ArbitrumL1ERC20GatewayLike _l2ERC20GatewayRouter,
        address _l3RefundL3Address,
        IERC20 _l2Usdc,
        ICCTPTokenMessenger _cctpTokenMessenger,
        uint32 _circleDomainId,
        FunderInterface _customGasTokenFunder,
        uint256 _l3MaxSubmissionCost,
        uint256 _l3GasPrice
    )
        Arbitrum_CustomGasToken_AdapterBase(
            _l2ArbitrumInbox,
            _l2ERC20GatewayRouter,
            _l3RefundL3Address,
            _l2Usdc,
            _cctpTokenMessenger,
            _circleDomainId,
            _customGasTokenFunder,
            _l3MaxSubmissionCost,
            _l3GasPrice
        )
        ForwarderBase()
    {}

    /**
     * @notice Bridge tokens to an AVM L3.
     * @notice This contract must hold at least getL2CallValue() amount of ETH or custom gas token
     * to send a message via the Inbox successfully, or the message will get stuck.
     * @param l2Token L2 token to send.
     * @param amount Amount of L2 tokens to deposit and L3 tokens to receive.
     */
    function relayTokens(
        address l2Token,
        address,
        uint256 amount,
        address
    ) external payable override {
        // The second field is hardcoded as address(0) since AVM gateway routers do not bridge a source token
        // to a specified destination token, but instead derives the L2 token in the gateway router. Therefore,
        // the second argument is not used by the adapter's bridging logic.
        _relayTokens(l2Token, address(0), amount, l3SpokePool);
        emit TokensForwarded(l2Token, amount);
    }

    /**
     * @notice Send cross-chain message to target on an AVM L3.
     * @notice This contract must hold at least getL2CallValue() amount of the custom gas token
     * to send a message via the Inbox successfully, or the message will get stuck.
     * @param target Contract on the AVM L3 that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes memory message) external payable override onlyAdmin {
        _relayMessage(target, message);
        emit MessageForwarded(target, message);
    }

    function _requireAdminSender() internal virtual override onlyFromCrossDomainAdmin {}
}
