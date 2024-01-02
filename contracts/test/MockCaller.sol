// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../interfaces/USSSpokePoolInterface.sol";
import "../interfaces/SpokePoolInterface.sol";

// Used for calling SpokePool.sol functions from a contract instead of an EOA. Can be used to simulate aggregator
// or pooled relayer behavior. Makes all calls from constructor to make sure SpokePool is not relying on checking the
// caller's code size which is 0 at construction time.

contract MockUSSCaller {
    constructor(
        address _spokePool,
        uint32 rootBundleId,
        USSSpokePoolInterface.USSRelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) {
        require(_spokePool != address(this), "spokePool not external");
        USSSpokePoolInterface(_spokePool).executeUSSRelayerRefundLeaf(rootBundleId, relayerRefundLeaf, proof);
    }
}

contract MockCaller {
    constructor(
        address _spokePool,
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) {
        require(_spokePool != address(this), "spokePool not external");
        SpokePoolInterface(_spokePool).executeRelayerRefundLeaf(rootBundleId, relayerRefundLeaf, proof);
    }
}
