// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ForwarderBase } from "./ForwarderBase.sol";
import { ArbitrumL1ERC20GatewayLike } from "../interfaces/ArbitrumBridgeInterfaces.sol";
import { CrossDomainAddressUtils } from "../libraries/CrossDomainAddressUtils.sol";

/**
 * @title Arbitrum_Forwarder
 * @notice This contract expects to receive messages and tokens from an authorized contract on a previous layer and forwards them to
 * contracts on the subsequent layer. It rejects messages which do not originate from a cross domain admin.
 * @custom:security-contact bugs@across.to
 */
contract Arbitrum_Forwarder is ForwarderBase {
    ArbitrumL1ERC20GatewayLike public immutable arbitrumGatewayRouter;

    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == CrossDomainAddressUtils._applyL1ToL2Alias(crossDomainAdmin), "ONLY_COUNTERPART_GATEWAY");
        _;
    }

    /**
     * @notice Constructs an Arbitrum-specific forwarder contract.
     * @dev Since this is a proxy contract, we only set immutable variables in the constructor, and leave everything else to be initialized.
     * This includes variables like the cross domain admin.
     */
    constructor(ArbitrumL1ERC20GatewayLike _arbitrumGatewayRouter) ForwarderBase() {
        arbitrumGatewayRouter = _arbitrumGatewayRouter;
    }

    /**
     * @notice Relays `currentLayerToken` to the next layer between the current layer and the one which contains `target`.
     * @param currentLayerToken The current layer's address of the token to send to the subsequent layer.
     * @param amount The amount of the token to send to the subsequent layer.
     * @param target The contract which will ultimately receive `amount` of `currentLayerToken`.
     * @dev The first field is discarded since it contains the address of the previous layer's token, which was used to derive this layer's token
     * address.
     */
    function relayTokens(
        address,
        address currentLayerToken,
        uint256 amount,
        address target
    ) external payable override onlyAdmin {
        address remoteToken = remoteTokens[target][currentLayerToken] == address(0)
            ? arbitrumGatewayRouter.calculateL2TokenAddress(currentLayerToken)
            : remoteTokens[target][currentLayerToken];
        _relayTokens(currentLayerToken, remoteToken, amount, target);
    }

    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}
}
