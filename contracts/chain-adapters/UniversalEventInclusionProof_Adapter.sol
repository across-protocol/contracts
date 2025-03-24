// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";

import { AdapterStore } from "../libraries/AdapterStore.sol";
import "../libraries/OFTTransportAdapter.sol";

/**
 * @notice Adapter to be used to relay messages to L2 SpokePools that have light client and verification contracts
 * that can verify event inclusion proofs.
 */
contract UniversalEventInclusionProof_Adapter is AdapterInterface, OFTTransportAdapter {
    // Chain id of the chain this adapter helps bridge to.
    uint256 public immutable DESTINATION_CHAIN_ID;

    // Helper storage contract to support bridging via differnt token standards: OFT, XERC20
    AdapterStore public immutable ADAPTER_STORE;

    error NotImplemented();

    event RelayedMessage(address indexed target, bytes message);

    constructor(
        address _adapterStore,
        uint256 _dstChainId,
        uint32 _oftDstEid,
        uint256 _oftFeeCap
    ) OFTTransportAdapter(_oftDstEid, _oftFeeCap) {
        DESTINATION_CHAIN_ID = _dstChainId;
        ADAPTER_STORE = AdapterStore(_adapterStore);
    }

    /**
     * @notice Emits an event containing the message that we can submit to the target spoke pool via
     * event inclusion proof.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        emit RelayedMessage(target, message);
    }

    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override {
        address oftMessenger = _getOftMessenger(l1Token);
        if (oftMessenger != address(0)) {
            _transferViaOFT(IERC20(l1Token), IOFT(oftMessenger), to, amount);
        } else {
            revert NotImplemented();
        }
    }

    function _getOftMessenger(address _token) internal view returns (address) {
        return ADAPTER_STORE.oftMessengers(DESTINATION_CHAIN_ID, _token);
    }
}
