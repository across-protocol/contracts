// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { HypXERC20Adapter } from "./HypXERC20Adapter.sol";
import { AdapterStore, MessengerTypes } from "../AdapterStore.sol";

// A wrapper of `HypXERC20Adapter` to be used by chain-specific adapters
contract HypXERC20AdapterWithStore is HypXERC20Adapter {
    // Helper storage contract to keep track of token => Hyperlane router relationships
    AdapterStore public immutable HYP_XERC20_ADAPTER_STORE;

    constructor(
        uint32 _hypXERC20DstDomain,
        uint256 _feeCap,
        address _adapterStore
    ) HypXERC20Adapter(_hypXERC20DstDomain, _feeCap) {
        HYP_XERC20_ADAPTER_STORE = AdapterStore(_adapterStore);
    }

    function _getHypXERC20Router(address _token) internal view returns (address) {
        return HYP_XERC20_ADAPTER_STORE.crossChainMessengers(MessengerTypes.HYP_XERC20_ROUTER, HYP_DST_DOMAIN, _token);
    }
}
