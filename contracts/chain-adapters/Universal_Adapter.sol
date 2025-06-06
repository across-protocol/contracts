// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";

import "../libraries/CircleCCTPAdapter.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";
import { HubPoolStore } from "./utilities/HubPoolStore.sol";
import { IOFT } from "../interfaces/IOFT.sol";
import { OFTTransportAdapterWithStore } from "../libraries/OFTTransportAdapterWithStore.sol";

interface IOwnable {
    function owner() external view returns (address);
}

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed. Designed to be used as a singleton contract that can be used to relay
 * messages to multiple SpokePools on different chains.
 * @dev This contract should NOT be reused to send messages to SpokePools that have the same address on different L2s.
 * @dev This contract can be redeployed to point to a new HubPoolStore if the data store gets corrupted and new data
 * can't get written to the store for some reason. The corresponding Universal_SpokePool contract will
 * also need to be redeployed to point to the new HubPoolStore.
 * @custom:security-contact bugs@across.to
 */
contract Universal_Adapter is AdapterInterface, CircleCCTPAdapter, OFTTransportAdapterWithStore {
    /// @notice Contract that stores calldata to be relayed to L2 via storage proofs.
    HubPoolStore public immutable DATA_STORE;

    error NotImplemented();

    constructor(
        HubPoolStore _store,
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _cctpDestinationDomainId,
        address _adapterStore,
        uint32 _oftDstEid,
        uint256 _oftFeeCap
    )
        CircleCCTPAdapter(_l1Usdc, _cctpTokenMessenger, _cctpDestinationDomainId)
        OFTTransportAdapterWithStore(_oftDstEid, _oftFeeCap, _adapterStore)
    {
        DATA_STORE = _store;
    }

    /**
     * @notice Saves calldata in a simple storage contract whose state can be proven and relayed to L2.
     * @param target Contract on the destination that will receive the message. Unused if the message is created
     * by the HubPool admin.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        // Admin messages are stored differently in the data store than non-admin messages, because admin
        // messages must only be sent to a single target on a specific L2 chain. Non-admin messages are sent
        // to any target on any L2 chain because the only type of an non-admin message is the result of a
        // HubPool.executeRootBundle() call which attempts to relay a relayRootBundle() call to all SpokePools using
        // this adapter. Therefore, non-admin messages are stored optimally in the data store
        // by only storing the message once and allowing any SpokePool target to read it via storage proofs.

        // We assume that the HubPool is delegatecall-ing into this function, therefore address(this) is the HubPool's
        // address. As a result, we can determine whether this message is an admin function based on the msg.sender.
        // If an admin sends a message that could have been relayed as a non-admin message (e.g. the admin
        // calls executeRootBundle()), then the message won't be stored optimally in the data store, but the
        // message can still be delivered to the target.
        bool isAdminSender = msg.sender == IOwnable(address(this)).owner();
        DATA_STORE.storeRelayMessageCalldata(target, message, isAdminSender);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Relays tokens from L1 to L2.
     * @dev This function uses CircleCCTPAdapter to relay USDC and OFTTransportAdapterWithStore to relay
     * OFT tokens to L2 chains that support these methods. Relaying other tokens will cause this function
     * to revert.
     * @param l1Token Address of the token on L1.
     * @param l2Token Address of the token on L2. Unused
     * @param amount Amount of tokens to relay.
     * @param to Address to receive the tokens on L2. Should be SpokePool address.
     */
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override {
        address oftMessenger = _getOftMessenger(l1Token);
        if (_isCCTPEnabled() && l1Token == address(usdcToken)) {
            _transferUsdc(to, amount);
        } else if (oftMessenger != address(0)) {
            _transferViaOFT(IERC20(l1Token), IOFT(oftMessenger), to, amount);
        } else {
            revert NotImplemented();
        }
    }
}
