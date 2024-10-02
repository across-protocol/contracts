// SPDX-License-Identifier: BUSL-1.1

// Arbitrum only supports v0.8.19
// See https://docs.arbitrum.io/for-devs/concepts/differences-between-arbitrum-ethereum/solidity-support#differences-from-solidity-on-ethereum
pragma solidity ^0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ArbitrumL2ERC20GatewayLike } from "../../interfaces/ArbitrumBridge.sol";
import { WithdrawalAdapterBase } from "./WithdrawalAdapterBase.sol";
import { ITokenMessenger } from "../../external/interfaces/CCTPInterfaces.sol";

/**
 * @title Arbitrum_WithdrawalAdapter
 * @notice This contract interfaces with L2-L1 token bridges and withdraws tokens to a single address on L1.
 * @dev This contract should be deployed on Arbitrum L2s which only use CCTP or the canonical Arbitrum gateway router to withdraw tokens.
 * @custom:security-contact bugs@across.to
 */
contract Arbitrum_WithdrawalAdapter is WithdrawalAdapterBase {
    using SafeERC20 for IERC20;

    // Error which triggers when the supplied L1 token does not match the Arbitrum gateway router's expected L2 token.
    error InvalidTokenMapping();

    /*
     * @notice Constructs the Arbitrum_WithdrawalAdapter.
     * @param _l2Usdc Address of native USDC on the L2.
     * @param _cctpTokenMessenger Address of the CCTP token messenger contract on L2.
     * @param _destinationCircleDomainId Circle's assigned CCTP domain ID for the destination network. For Ethereum, this is 0.
     * @param _l2GatewayRouter Address of the Arbitrum l2 gateway router contract.
     * @param _tokenRecipient L1 Address which will unconditionally receive tokens withdrawn from this contract.
     */
    constructor(
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _destinationCircleDomainId,
        address _l2GatewayRouter,
        address _tokenRecipient
    )
        WithdrawalAdapterBase(
            _l2Usdc,
            _cctpTokenMessenger,
            _destinationCircleDomainId,
            _l2GatewayRouter,
            _tokenRecipient
        )
    {}

    /*
     * @notice Calls CCTP or the Arbitrum gateway router to withdraw tokens back to the TOKEN_RECIPIENT L1 address.
     * @param l1Token Address of the L1 token to receive.
     * @param l2Token Address of the L2 token to send back.
     * @param amountToReturn Amount of l2Token to send back.
     */
    function withdrawToken(
        address l1Token,
        address l2Token,
        uint256 amountToReturn
    ) public override {
        // If the l2TokenAddress is UDSC, we need to use the CCTP bridge.
        if (_isCCTPEnabled() && l2Token == address(usdcToken)) {
            _transferUsdc(TOKEN_RECIPIENT, amountToReturn);
        } else {
            // Otherwise, we use the Arbitrum ERC20 Gateway router.
            ArbitrumL2ERC20GatewayLike tokenBridge = ArbitrumL2ERC20GatewayLike(L2_TOKEN_GATEWAY);
            // If the gateway router's expected L2 token address does not match then revert. This check does not actually
            // impact whether the bridge will succeed, since the ERC20 gateway router only requires the L1 token address, but
            // it is added here to potentially catch scenarios where there was a mistake in the calldata.
            if (tokenBridge.calculateL2TokenAddress(l1Token) != l2Token) revert InvalidTokenMapping();
            //slither-disable-next-line unused-return
            tokenBridge.outboundTransfer(
                l1Token, // _l1Token. Address of the L1 token to bridge over.
                TOKEN_RECIPIENT, // _to. Withdraw, over the bridge, to the recipient.
                amountToReturn, // _amount.
                "" // _data. We don't need to send any data for the bridging action.
            );
        }
    }
}
