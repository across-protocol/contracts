// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "../ZkSync_SpokePool.sol";

/**
 * @notice Mock ZkSync Spoke pool allowing deployer to test internal functions.
 */
contract MockZkSync_SpokePool is ZkSync_SpokePool {
    function bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) public {
        _bridgeTokensToHubPool(relayerRefundLeaf);
    }
}
