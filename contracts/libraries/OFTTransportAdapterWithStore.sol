// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { OFTTransportAdapter } from "./OFTTransportAdapter.sol";
import { AdapterStore, MessengerTypes } from "../AdapterStore.sol";

// A wrapper of `OFTTransportAdapter` to be used by chain-specific adapters
contract OFTTransportAdapterWithStore is OFTTransportAdapter {
    // Helper storage contract to keep track of token => IOFT relationships
    AdapterStore public immutable OFT_ADAPTER_STORE;

    constructor(
        uint32 _oftDstEid,
        uint256 _feeCap,
        address _adapterStore
    ) OFTTransportAdapter(_oftDstEid, _feeCap) {
        OFT_ADAPTER_STORE = AdapterStore(_adapterStore);
    }

    function _getOftMessenger(address _token) internal view returns (address) {
        return OFT_ADAPTER_STORE.crossChainMessengers(MessengerTypes.OFT_MESSENGER, OFT_DST_EID, _token);
    }
}
