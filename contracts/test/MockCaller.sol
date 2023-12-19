// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../interfaces/USSSpokePoolInterface.sol";
import "../interfaces/SpokePoolInterface.sol";

// Used for calling SpokePool.sol functions from a contract instead of an EOA. Can be used to simulate aggregator
// or pooled relayer behavior.
contract MockCaller {
    address private spokePool;

    constructor(address _spokePool) {
        require(_spokePool != address(this), "spokePool not external");
        spokePool = _spokePool;
    }

    function executeUSSRelayerRefundLeaf(
        uint32 rootBundleId,
        USSSpokePoolInterface.USSRelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) external {
        USSSpokePoolInterface(spokePool).executeUSSRelayerRefundLeaf(rootBundleId, relayerRefundLeaf, proof);
    }

    function executeRelayerRefundLeaf(
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) external {
        SpokePoolInterface(spokePool).executeRelayerRefundLeaf(rootBundleId, relayerRefundLeaf, proof);
    }
}
