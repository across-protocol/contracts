// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ForwarderBase } from "./ForwarderBase.sol";
import { LibOptimismUpgradeable } from "@openzeppelin/contracts-upgradeable/crosschain/optimism/LibOptimismUpgradeable.sol";
import { Lib_PredeployAddresses } from "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

/**
 * @title Ovm_Forwarder
 * @notice This contract expects to receive messages and tokens from the hub pool on L1 and forwards messages to a spoke pool on L3.
 * It rejects messages which do not originate from a cross domain admin, which is set as the hub pool.
 * @dev This forwarder assumes that the cross domain messenger predeploy contract is set to the same contract as the standard OpStack predeploy.
 * (0x4200000000000000000000000000000000000007). This is because in order to determine the L1 msg.sender of a cross-chain message, we must
 * query information from that contract.
 * @custom:security-contact bugs@across.to
 */
contract Ovm_Forwarder is ForwarderBase {
    // Address of the cross domain messenger contract.
    address public constant MESSENGER = Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER;

    error NotCrossDomainAdmin();

    /**
     @notice Constructs an Ovm specific forwarder contract.
     */
    constructor() ForwarderBase() {}

    function _requireAdminSender() internal view override {
        if (LibOptimismUpgradeable.crossChainSender(MESSENGER) != crossDomainAdmin) revert NotCrossDomainAdmin();
    }
}
