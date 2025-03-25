// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";

import "../libraries/CircleCCTPAdapter.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";
import { HubPoolStore } from "../HubPoolStore.sol";

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed.
 * @dev This contract should NOT be reused to send messages to SpokePools that have the same address on different L2s.
 * @dev This contract should be CAREFULLY used when relaying admin root bundles to SpokePools and should NOT be used
 * if the admin root bundle's relayerRefundRoot and slowRelayRoots are identical to a pending root bundle proposal.
 * @dev This contract can be redeployed to point to a new HubPoolStore if the data store gets corrupted and new data
 * can't get written to the store for some reason. The corresponding UniversalStorageProof_SpokePool contract will
 * also need to be redeployed to point to the new HubPoolStore.
 */
contract UniversalStorageProof_Adapter is AdapterInterface, CircleCCTPAdapter {
    // Contract on which to write calldata to be relayed to L2 via storage proofs.
    HubPoolStore public immutable DATA_STORE;

    error NotImplemented();

    constructor(
        HubPoolStore _store,
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _cctpDestinationDomainId
    ) CircleCCTPAdapter(_l1Usdc, _cctpTokenMessenger, _cctpDestinationDomainId) {
        DATA_STORE = _store;
    }

    /**
     * @notice Saves root bundle data in a simple storage contract that can be proven and relayed to L2.
     * @dev Uses gas optimized function to write root bundle data to be relayed to all L2 spoke pools.
     * @param target Contract on the destination that will receive the message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        bytes4 selector = bytes4(message[:4]);
        if (selector == SpokePoolInterface.relayRootBundle.selector) {
            // If the message contains a relayRootBundle() call for the target SpokePool, then
            // store the data without a specific target in-mind. This is a gas optimization so that we only update a
            // storage slot in the HubPoolStore once per root bundle execution, since the data passed to relayRootBundle
            // will be the same for all chains.
            DATA_STORE.storeRelayRootsCalldata(target, message);
        } else {
            DATA_STORE.storeRelayAdminFunctionCalldata(target, message);
        }

        emit MessageRelayed(target, message);
    }

    /**
     * @notice Relays tokens from L1 to L2.
     * @dev This function only uses the CircleCCTPAdapter to relay USDC tokens to CCTP enabled L2 chains.
     * Relaying other tokens will cause this function to revert.
     * @param l1Token Address of the token on L1.
     * @param l2Token Address of the token on L2.
     * @param amount Amount of tokens to relay.
     * @param to Address to receive the tokens on L2. Should be SpokePool address.
     */
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override {
        if (_isCCTPEnabled() && l1Token == address(usdcToken)) {
            _transferUsdc(to, amount);
        } else {
            revert NotImplemented();
        }
    }
}
