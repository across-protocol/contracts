// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Arbitrum_L2_Forwarder, ITokenMessenger } from "./Arbitrum_L2_Forwarder.sol";
import { ArbitrumInboxLike, ArbitrumL1ERC20GatewayLike } from "../interfaces/ArbitrumBridgeInterfaces.sol";
import { LibOptimismUpgradeable } from "@openzeppelin/contracts-upgradeable/crosschain/optimism/LibOptimismUpgradeable.sol";
import { Lib_PredeployAddresses } from "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Contract containing logic to send messages from an OVM L2 to an AVM L3.
 * @dev This contract is very similar to the Arbitrum_Adapter. It is meant to bridge
 * tokens and send messages over a bridge which uses a custom gas token, except this contract makes
 * the assumption that it is deployed on an OpStack L2.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Ovm_L2_Forwarder is Arbitrum_L2_Forwarder {
    using SafeERC20 for IERC20;

    address public constant MESSENGER = Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER;

    error NotCrossDomainAdmin();

    /**
     * @notice Constructs new L2 Forwarder.
     * @param _l2ArbitrumInbox Inbox helper contract to send messages to L3.
     * @param _l2ERC20GatewayRouter ERC20 gateway router contract to send tokens to L3.
     * @param _l3RefundL3Address L3 address to receive gas refunds on after a message is relayed.
     * @param _l2Usdc Native USDC address on L2.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     * @param _circleDomainId CCTP domain ID for the L3 network.
     * @param _l3MaxSubmissionCost Amount of gas token allocated to pay for the base submission fee. The base
     * submission fee is a parameter unique to AVM retryable transactions. This value is hardcoded
     * and used for all messages sent by this adapter.
     * @param _l3GasPrice gas price bid for message execution on L3.
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
        Arbitrum_L2_Forwarder(
            _l2ArbitrumInbox,
            _l2ERC20GatewayRouter,
            _l3RefundL3Address,
            _l2Usdc,
            _cctpTokenMessenger,
            _circleDomainId,
            _l3MaxSubmissionCost,
            _l3GasPrice
        )
    {}

    function _requireAdminSender() internal view override {
        if (LibOptimismUpgradeable.crossChainSender(MESSENGER) != crossDomainAdmin) revert NotCrossDomainAdmin();
    }
}
