// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ForwarderBase } from "./ForwarderBase.sol";
import { LibOptimismUpgradeable } from "@openzeppelin/contracts-upgradeable/crosschain/optimism/LibOptimismUpgradeable.sol";
import { Lib_PredeployAddresses } from "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

/**
 * @title Ovm_Forwarder
 * @notice This contract expects to receive messages and tokens from an authorized contract on a previous layer and forwards them to
 * contracts on the subsequent layer. It rejects messages which do not originate from a cross domain admin.
 * @custom:security-contact bugs@across.to
 */
contract Ovm_Forwarder is ForwarderBase {
    address public constant MESSENGER = Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER;

    error NotCrossDomainAdmin();
    error UninitializedRemoteToken(address currentLayerToken);

    /**
     @notice Constructs an Ovm specific forwarder contract.
     */
    constructor() ForwarderBase() {}

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
        address remoteToken = remoteTokens[target][currentLayerToken];
        if (remoteToken == address(0)) revert UninitializedRemoteToken(currentLayerToken);
        _relayTokens(currentLayerToken, remoteToken, amount, target);
    }

    function _requireAdminSender() internal view override {
        if (LibOptimismUpgradeable.crossChainSender(MESSENGER) != crossDomainAdmin) revert NotCrossDomainAdmin();
    }
}
