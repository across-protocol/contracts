// SPDX-License-Identifier: BUSL-1.1

// Arbitrum only supports v0.8.19
// See https://docs.arbitrum.io/for-devs/concepts/differences-between-arbitrum-ethereum/solidity-support#differences-from-solidity-on-ethereum
pragma solidity ^0.8.19;

import "../../libraries/CircleCCTPAdapter.sol";
import { StandardBridgeLike } from "../../Arbitrum_SpokePool.sol";

/**
 * @notice AVM specific bridge adapter. Implements logic to bridge tokens back to mainnet.
 * @custom:security-contact bugs@across.to
 */

/*
 * @notice Interface for the Across Arbitrum_SpokePool contract. Used to access state which
 * can only be modified by admin functions.
 */
interface IArbitrum_SpokePool {
    function whitelistedTokens(address) external view returns (address);
}

/**
 * @title Adapter for interacting with bridges from the Arbitrum One L2 to Ethereum mainnet.
 * @notice This contract is used to share L2-L1 bridging logic with other L2 Across contracts.
 */
contract Arbitrum_WithdrawalAdapter is CircleCCTPAdapter {
    struct WithdrawalInformation {
        // L1 address of the recipient.
        address recipient;
        // Address of l2 token to withdraw.
        address l2TokenAddress;
        // Amount of l2 Token to return.
        uint256 amountToReturn;
    }

    IArbitrum_SpokePool public immutable spokePool;
    address public immutable l2GatewayRouter;

    /*
     * @notice constructs the withdrawal adapter.
     * @param _l2Usdc address of native USDC on the L2.
     * @param _cctpTokenMessenger address of the CCTP token messenger contract on L2.
     * @param _spokePool address of the spoke pool on L2.
     * @param _l2GatewayRouter address of the Arbitrum l2 gateway router contract.
     */
    constructor(
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        IArbitrum_SpokePool _spokePool,
        address _l2GatewayRouter
    ) CircleCCTPAdapter(_l2Usdc, _cctpTokenMessenger, CircleDomainIds.Ethereum) {
        spokePool = _spokePool;
        l2GatewayRouter = _l2GatewayRouter;
    }

    /*
     * @notice withdraws tokens to Ethereum given the input parameters.
     * @param withdrawalInformation array containing information to withdraw a token. Includes the L1 recipient
     * address, the amount to withdraw, and the token address of the L2 token to withdraw.
     */
    function withdrawTokens(WithdrawalInformation[] calldata withdrawalInformation) external {
        uint256 informationLength = withdrawalInformation.length;
        WithdrawalInformation calldata withdrawal;
        for (uint256 i = 0; i < informationLength; ++i) {
            withdrawal = withdrawalInformation[i];
            withdrawToken(withdrawal.recipient, withdrawal.amountToReturn, withdrawal.l2TokenAddress);
        }
    }

    /*
     * @notice Calls CCTP or the Arbitrum gateway router to withdraw tokens back to the `tokenRetriever`. The
     * bridge will not be called if the token is not in the Arbitrum_SpokePool's `whitelistedTokens` mapping.
     * @param recipient L1 address of the recipient.
     * @param amountToReturn amount of l2Token to send back.
     * @param l2TokenAddress address of the l2Token to send back.
     */
    function withdrawToken(
        address recipient,
        uint256 amountToReturn,
        address l2TokenAddress
    ) public {
        // If the l2TokenAddress is UDSC, we need to use the CCTP bridge.
        if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
            _transferUsdc(recipient, amountToReturn);
        } else {
            // Check that the Ethereum counterpart of the L2 token is stored on this contract.
            // Tokens will only be bridged if they are whitelisted by the spoke pool.
            address ethereumTokenToBridge = spokePool.whitelistedTokens(l2TokenAddress);
            require(ethereumTokenToBridge != address(0), "Uninitialized mainnet token");
            //slither-disable-next-line unused-return
            StandardBridgeLike(l2GatewayRouter).outboundTransfer(
                ethereumTokenToBridge, // _l1Token. Address of the L1 token to bridge over.
                recipient, // _to. Withdraw, over the bridge, to the l1 hub pool contract.
                amountToReturn, // _amount.
                "" // _data. We don't need to send any data for the bridging action.
            );
        }
    }
}
