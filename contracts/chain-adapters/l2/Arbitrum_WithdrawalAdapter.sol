// SPDX-License-Identifier: BUSL-1.1

// Arbitrum only supports v0.8.19
// See https://docs.arbitrum.io/for-devs/concepts/differences-between-arbitrum-ethereum/solidity-support#differences-from-solidity-on-ethereum
pragma solidity ^0.8.19;

import { ArbitrumL2ERC20GatewayLike } from "../../interfaces/ArbitrumBridgeInterfaces.sol";
import { WithdrawalAdapter, ITokenMessenger } from "./WithdrawalAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice AVM specific bridge adapter. Implements logic to bridge tokens back to mainnet.
 * @custom:security-contact bugs@across.to
 */

/**
 * @title Adapter for interacting with bridges from the Arbitrum One L2 to Ethereum mainnet.
 * @notice This contract is used to share L2-L1 bridging logic with other L2 Across contracts.
 */
contract Arbitrum_WithdrawalAdapter is WithdrawalAdapter {
    using SafeERC20 for IERC20;

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
        address _l2GatewayRouter
    ) WithdrawalAdapter(_l2Usdc, _cctpTokenMessenger, _l2GatewayRouter) {}

    /*
     * @notice Calls CCTP or the Arbitrum gateway router to withdraw tokens back to the `tokenRetriever`. The
     * bridge will not be called if the token is not in the Arbitrum_SpokePool's `whitelistedTokens` mapping.
     * @param recipient L1 address of the recipient.
     * @param amountToReturn amount of l2Token to send back.
     * @param l2TokenAddress address of the l2Token to send back.
     */
    function withdrawToken(
        address recipient,
        address l1TokenAddress,
        address l2TokenAddress,
        uint256 amountToReturn
    ) public override {
        // If the l2TokenAddress is UDSC, we need to use the CCTP bridge.
        if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
            _transferUsdc(recipient, amountToReturn);
        } else {
            require(l1TokenAddress != address(0), "Uninitialized mainnet token");
            ArbitrumL2ERC20GatewayLike tokenBridge = ArbitrumL2ERC20GatewayLike(l2Gateway);
            require(tokenBridge.calculateL2TokenAddress(l1TokenAddress) == l2TokenAddress, "Invalid token mapping");
            //slither-disable-next-line unused-return
            tokenBridge.outboundTransfer(
                l1TokenAddress, // _l1Token. Address of the L1 token to bridge over.
                recipient, // _to. Withdraw, over the bridge, to the recipient.
                amountToReturn, // _amount.
                "" // _data. We don't need to send any data for the bridging action.
            );
        }
    }
}
