// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Arbitrum_CustomGasToken_L2_Forwarder, ICCTPTokenMessenger, FunderInterface } from "./Arbitrum_CustomGasToken_L2_Forwarder.sol";
import { ArbitrumCustomGasTokenInbox, ArbitrumL1ERC20GatewayLike } from "../interfaces/ArbitrumBridgeInterfaces.sol";
import { LibOptimismUpgradeable } from "@openzeppelin/contracts-upgradeable/crosschain/optimism/LibOptimismUpgradeable.sol";
import { Lib_PredeployAddresses } from "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Contract containing logic to send messages from an OVM L2 to an Arbitrum-like L3.
 * @dev This contract is very similar to Arbitrum_CustomGasToken_Adapter. It is meant to bridge
 * tokens and send messages over a bridge which uses a custom gas token, except this contract makes
 * the assumption that it is deployed on an OpStack L2.
 */

// solhint-disable-next-line contract-name-camelcase
contract Ovm_CustomGasToken_L2_Forwarder is Arbitrum_CustomGasToken_L2_Forwarder {
    using SafeERC20 for IERC20;

    address public constant MESSENGER = Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER;

    error NotCrossDomainAdmin();

    constructor(
        ArbitrumCustomGasTokenInbox _l2ArbitrumInbox,
        ArbitrumL1ERC20GatewayLike _l2ERC20GatewayRouter,
        address _l3RefundL3Address,
        IERC20 _l2Usdc,
        ICCTPTokenMessenger _cctpTokenMessenger,
        uint32 _circleDomainId,
        FunderInterface _customGasTokenFunder,
        uint256 _l3MaxSubmissionCost,
        uint256 _l3GasPrice,
        address _l3SpokePool,
        address _crossDomainAdmin
    )
        Arbitrum_CustomGasToken_L2_Forwarder(
            _l2ArbitrumInbox,
            _l2ERC20GatewayRouter,
            _l3RefundL3Address,
            _l2Usdc,
            _cctpTokenMessenger,
            _circleDomainId,
            _customGasTokenFunder,
            _l3MaxSubmissionCost,
            _l3GasPrice,
            _l3SpokePool,
            _crossDomainAdmin
        )
    {}

    function _requireAdminSender() internal view override {
        if (LibOptimismUpgradeable.crossChainSender(MESSENGER) != crossDomainAdmin) revert NotCrossDomainAdmin();
    }
}
