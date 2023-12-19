// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../interfaces/USSSpokePoolInterface.sol";

// Used for calling SpokePool.sol functions from a contract instead of an EOA. Can be used to simulate aggregator
// or pooled relayer behavior.
contract MockCaller {
    USSSpokePoolInterface private spokePool;

    constructor(address _spokePool) {
        require(_spokePool != address(this), "spokePool not external");
        spokePool = USSSpokePoolInterface(_spokePool);
    }

    function executeRelayerRefundLeaf(
        uint32 rootBundleId,
        USSSpokePoolInterface.USSRelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) external {
        spokePool.executeUSSRelayerRefundLeaf(rootBundleId, relayerRefundLeaf, proof);
    }

    function executeSlowRelayLeaf(
        USSSpokePoolInterface.USSSlowFill memory slowFillLeaf,
        uint32 rootBundleId,
        bytes32[] memory proof
    ) external {
        spokePool.executeUSSSlowRelayLeaf(slowFillLeaf, rootBundleId, proof);
    }
}
