// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "../../libraries/CircleCCTPAdapter.sol";

/**
 * @title Adapter for interacting with bridges from a generic L2 to Ethereum mainnet.
 * @notice This contract is used to share L2-L1 bridging logic with other Across contracts.
 */
abstract contract WithdrawalAdapter is CircleCCTPAdapter {
    struct WithdrawalInformation {
        // L1 address of the recipient.
        address recipient;
        // Address of l2 token to withdraw.
        address l2TokenAddress;
        // Amount of l2 Token to return.
        uint256 amountToReturn;
    }

    address public immutable l2Gateway;

    /*
     * @notice constructs the withdrawal adapter.
     * @param _l2Usdc address of native USDC on the L2.
     * @param _cctpTokenMessenger address of the CCTP token messenger contract on L2.
     * @param _l2Gateway address of the network's l2 token gateway/bridge contract.
     */
    constructor(
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        address _l2Gateway
    ) CircleCCTPAdapter(_l2Usdc, _cctpTokenMessenger, CircleDomainIds.Ethereum) {
        l2Gateway = _l2Gateway;
    }

    /*
     * @notice withdraws tokens to Ethereum given the input parameters.
     * @param withdrawalInformation array containing information to withdraw a token. Includes the L1 recipient
     * address, the amount to withdraw, and the token address of the L2 token to withdraw.
     */
    function withdrawTokens(WithdrawalInformation[] memory withdrawalInformation) external {
        uint256 informationLength = withdrawalInformation.length;
        WithdrawalInformation memory withdrawal;
        for (uint256 i = 0; i < informationLength; ++i) {
            withdrawal = withdrawalInformation[i];
            withdrawToken(withdrawal.recipient, withdrawal.amountToReturn, withdrawal.l2TokenAddress);
        }
    }

    /*
     * @notice implementation for withdrawing a specific token back to Ethereum. This is to be implemented
     * for each different L2, since each L2 has various mappings for L1<->L2 tokens.
     * @param recipient L1 address of the recipient.
     * @param amountToReturn amount of l2Token to send back.
     * @param l2TokenAddress address of the l2Token to send back.
     */
    function withdrawToken(
        address recipient,
        uint256 amountToReturn,
        address l2TokenAddress
    ) public virtual;
}
