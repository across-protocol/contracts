// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { V3SpokePoolInterface } from "../interfaces/V3SpokePoolInterface.sol";

library RelayDataHashLib {
    uint32 internal constant MAX_EXCLUSIVITY_PERIOD_SECONDS = 31_536_000;

    function resolveExclusivityDeadline(
        uint32 exclusivityParameter,
        uint32 currentTime
    ) internal pure returns (uint32) {
        if (exclusivityParameter > 0 && exclusivityParameter <= MAX_EXCLUSIVITY_PERIOD_SECONDS) {
            return exclusivityParameter + currentTime;
        }
        return exclusivityParameter;
    }

    function getRelayDataHash(
        V3SpokePoolInterface.V3RelayData memory relayData,
        uint256 chainId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(relayData, chainId));
    }
}
