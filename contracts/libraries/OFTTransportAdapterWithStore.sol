// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { OFTTransportAdapter } from "./OFTTransportAdapter.sol";
import { AdapterStore, MessengerTypes } from "../AdapterStore.sol";

/**
 * @dev A wrapper of `OFTTransportAdapter` to be used by chain-specific adapters
 * @custom:security-contact bugs@across.to
 */
contract OFTTransportAdapterWithStore is OFTTransportAdapter {
    /** @notice Helper storage contract to keep track of token => IOFT relationships */
    AdapterStore public immutable OFT_ADAPTER_STORE;

    /**
     * @notice Initializes the OFTTransportAdapterWithStore contract
     * @param _oftDstEid The endpoint ID that OFT protocol will transfer funds to
     * @param _feeCap Fee cap checked before sending messages to OFTMessenger
     * @param _adapterStore Address of the AdapterStore contract
     */
    constructor(uint32 _oftDstEid, uint256 _feeCap, address _adapterStore) OFTTransportAdapter(_oftDstEid, _feeCap) {
        OFT_ADAPTER_STORE = AdapterStore(_adapterStore);
    }

    /**
     * @notice Retrieves the OFT messenger address for a given token
     * @param _token Token address to look up messenger for
     * @return Address of the OFT messenger for the token
     */
    function _getOftMessenger(address _token) internal view returns (address) {
        return OFT_ADAPTER_STORE.crossChainMessengers(MessengerTypes.OFT_MESSENGER, OFT_DST_EID, _token);
    }
}
