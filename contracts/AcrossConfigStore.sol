// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Allows admin to set and update configuration settings for full contract system. These settings are designed
 * to be consumed by off-chain bots, rather than by other contracts.
 * @dev This contract should not perform any validation on the setting values and should be owned by the governance
 * system of the full contract suite.
 * @custom:security-contact bugs@across.to
 */
contract AcrossConfigStore is Ownable, MultiCaller {
    // General dictionary where admin can associate variables with specific L1 tokens, like the Rate Model and Token
    // Transfer Thresholds.
    mapping(address => string) public l1TokenConfig;

    // General dictionary where admin can store global variables like `MAX_POOL_REBALANCE_LEAF_SIZE` and
    // `MAX_RELAYER_REPAYMENT_LEAF_SIZE` that off-chain agents can query.
    mapping(bytes32 => string) public globalConfig;

    event UpdatedTokenConfig(address indexed key, string value);
    event UpdatedGlobalConfig(bytes32 indexed key, string value);

    /**
     * @notice Updates token config.
     * @param l1Token the l1 token address to update value for.
     * @param value Value to update.
     */
    function updateTokenConfig(address l1Token, string memory value) external onlyOwner {
        l1TokenConfig[l1Token] = value;
        emit UpdatedTokenConfig(l1Token, value);
    }

    /**
     * @notice Updates global config.
     * @param key Key to update.
     * @param value Value to update.
     */
    function updateGlobalConfig(bytes32 key, string calldata value) external onlyOwner {
        globalConfig[key] = value;
        emit UpdatedGlobalConfig(key, value);
    }
}
