// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Allows admin to set and update configuration settings for full contract system. These settings are designed
 * to be consumed by off-chain bots, rather than by other contracts.
 * @dev This contract should not perform any validation on the setting values and should be owned by the governance
 * system of the full contract suite..
 */
contract GlobalConfigStore is Ownable, MultiCaller {
    // General dictionary where admin can store global variables like `MAX_POOL_REBALANCE_LEAF_SIZE` and
    // `MAX_RELAYER_REPAYMENT_LEAF_SIZE` that off-chain agents can query.
    mapping(bytes32 => string) public globalConfig;

    event UpdatedGlobalConfig(bytes32 indexed key, string value);

    /**
     * @notice Updates global uint config.
     * @param key Key to update.
     * @param value Value to update.
     */
    function updateGlobalConfig(bytes32 key, string value) external onlyOwner {
        uintGlobalConfig[key] = value;
        emit UpdatedGlobalConfig(key, value);
    }
}
