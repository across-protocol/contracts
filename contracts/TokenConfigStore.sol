// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Allows admin to set and update configuration settings for full contract system. These settings are designed
 * to be consumed by off-chain bots, rather than by other contracts.
 * @dev This contract should not perform any validation on the setting values and should be owned by the governance
 * system of the full contract suite.
 */
contract TokenConfigStore is Ownable, MultiCaller {
    // This will be queried by off-chain agents that need to compute realized LP fee %'s for deposit quote
    // timestamps. This contract does not validate the shape of the rate model, which is stored as a string to
    // enable arbitrary data encoding via a stringified JSON. Every L1 token enabled in the HubPool will be mapped
    // to one rate model.
    mapping(address => string) public l1TokenRateModels;

    // This will be queried by an off-chain dataworker to determine whether to send tokens from the HubPool to the
    // SpokePool via a pool rebalance, or just to save the amount to send in "runningBalances".
    mapping(address => uint256) public l1TokenTransferThresholds;

    event UpdatedRateModel(address indexed l1Token, string rateModel);
    event UpdatedTransferThreshold(address indexed l1Token, uint256 transferThreshold);

    /**
     * @notice Updates rate model string for L1 token.
     * @param l1Token the l1 token rate model to update.
     * @param rateModel the updated rate model.
     */
    function updateRateModel(address l1Token, string memory rateModel) external onlyOwner {
        l1TokenRateModels[l1Token] = rateModel;
        emit UpdatedRateModel(l1Token, rateModel);
    }

    /**
     * @notice Updates token transfer threshold percentage for L1 token.
     * @param l1Token the l1 token rate model to update.
     * @param transferThresholdPct the updated transfer threshold percentage.
     */
    function updateTransferThreshold(address l1Token, uint256 transferThresholdPct) external onlyOwner {
        l1TokenTransferThresholds[l1Token] = transferThresholdPct;
        emit UpdatedTransferThreshold(l1Token, transferThresholdPct);
    }
}
