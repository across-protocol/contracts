// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ForwarderBase } from "./ForwarderBase.sol";
import { CrossDomainAddressUtils } from "../libraries/CrossDomainAddressUtils.sol";

/**
 * @title Arbitrum_Forwarder
 * @notice This contract expects to receive messages and tokens from the hub pool on L1 and forwards messages to a spoke pool on L3.
 * It rejects messages which do not originate from a cross domain admin, which is set as the hub pool.
 * @custom:security-contact bugs@across.to
 */
contract Arbitrum_Forwarder is ForwarderBase {
    // On Arbitrum, L1 msg.senders are derived by aliasing a L1 address.
    modifier onlyFromCrossDomainAdmin() {
        require(msg.sender == CrossDomainAddressUtils.applyL1ToL2Alias(crossDomainAdmin), "ONLY_COUNTERPART_GATEWAY");
        _;
    }

    /**
     * @notice Constructs an Arbitrum-specific forwarder contract.
     * @dev Since this is a proxy contract, we only set immutable variables in the constructor, and leave everything else to be initialized.
     * This includes variables like the cross domain admin.
     */
    constructor() ForwarderBase() {}

    function _requireAdminSender() internal override onlyFromCrossDomainAdmin {}
}
