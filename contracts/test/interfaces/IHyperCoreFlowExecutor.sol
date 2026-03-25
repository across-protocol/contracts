// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CommonFlowParams } from "../../periphery/mintburn/Structs.sol";
import { DonationBox } from "../../chain-adapters/DonationBox.sol";

/**
 * @title IHyperCoreFlowExecutor
 * @notice Interface for HyperCoreFlowExecutor contract handling HyperCore interactions for transfer-to-core or swap-with-core actions after stablecoin bridge transactions
 * @custom:security-contact bugs@across.to
 */
interface IHyperCoreFlowExecutor {
    /**************************************
     *      PUBLIC VARIABLE GETTERS       *
     **************************************/

    /// @notice Common decimals scalars - parts per million decimals
    /// @return PPM_DECIMALS Parts per million decimals (6)
    function PPM_DECIMALS() external returns (uint256);

    /// @notice Parts per million scalar (10^6)
    /// @return PPM_SCALAR Parts per million scalar
    function PPM_SCALAR() external returns (uint256);

    /// @notice Decimals to use for Price calculations in limit order-related calculation functions
    /// @return PX_D Price decimals (8)
    function PX_D() external returns (uint8);

    /// @notice One in 1e8 format (10^8)
    /// @return ONEX1e8 One in 1e8 format
    function ONEX1e8() external returns (uint64);

    /// @notice The donation box contract.
    /// @return donationBox Address of the donation box contract
    function donationBox() external returns (DonationBox);

    /// @notice All operations performed in this contract are relative to this baseToken
    /// @return baseToken Address of the base token
    function baseToken() external returns (address);

    /**************************************
     *         FLOW FUNCTIONS             *
     **************************************/

    /**
     * @notice External entrypoint to execute flow when called via delegatecall from a handler. Works with params
     * checked by a handler. Params authorization by a handler is enforced via `onlyAuthorizedFlow` modifier
     * @param params Common flow parameters
     * @param maxUserSlippageBps Maximum user slippage in basis points
     */
    function executeFlow(CommonFlowParams memory params, uint256 maxUserSlippageBps) external;

    /// @notice External entrypoint to execute simple transfer flow (see `executeFlow` comment for details)
    /// @param params Common flow parameters
    function executeSimpleTransferFlow(CommonFlowParams memory params) external;

    /// @notice External entrypoint to execute fallback evm flow (see `executeFlow` comment for details)
    /// @param params Common flow parameters
    function fallbackHyperEVMFlow(CommonFlowParams memory params) external;

    /**
     * @notice Finalizes multiple swap flows associated with a final token, subject to the L1 Hyperliquid balance
     * @dev Caller is responsible for providing correct limitOrderOutput amounts per assosicated swap flow. The caller
     * has to estimate how much final tokens it received on core based on the input of the corresponding quote nonce
     * swap flow
     * @param finalToken The final token address
     * @param quoteNonces Array of quote nonces to finalize
     * @param limitOrderOuts Array of limit order outputs corresponding to each quote nonce
     * @return finalized Number of swaps successfully finalized
     */
    function finalizeSwapFlows(
        address finalToken,
        bytes32[] calldata quoteNonces,
        uint64[] calldata limitOrderOuts
    ) external returns (uint256 finalized);

    /**
     * @notice Activates a user account on Core by funding the account activation fee.
     * @param quoteNonce The nonce of the quote that is used to identify the user.
     * @param finalRecipient The address of the recipient of the funds.
     * @param fundingToken The address of the token that is used to fund the account activation fee.
     */
    function activateUserAccount(bytes32 quoteNonce, address finalRecipient, address fundingToken) external;

    /**
     * @notice Cancells a pending limit order by `cloid` with an intention to submit a new limit order in its place. To
     * be used for stale limit orders to speed up executing user transactions
     * @param finalToken The final token address
     * @param cloid The client order ID to cancel
     */
    function cancelLimitOrderByCloid(address finalToken, uint128 cloid) external;

    /**
     * @notice Submits a limit order from the bot
     * @param finalToken The final token address
     * @param priceX1e8 Price in 1e8 format
     * @param sizeX1e8 Size in 1e8 format
     * @param cloid The client order ID
     */
    function submitLimitOrderFromBot(address finalToken, uint64 priceX1e8, uint64 sizeX1e8, uint128 cloid) external;

    /**
     * @notice Set or update information for the token to use it in this contract
     * @dev To be able to use the token in the swap flow, FinalTokenInfo has to be set as well
     * @dev Setting core token info to incorrect values can lead to loss of funds. Should NEVER be unset while the
     * finalTokenParams are not unset
     * @param token The token address
     * @param coreIndex The HyperCore index of the token
     * @param canBeUsedForAccountActivation Whether the token can be used for account activation
     * @param accountActivationFeeCore The account activation fee in core units
     * @param bridgeSafetyBufferCore The bridge safety buffer in core units
     */
    function setCoreTokenInfo(
        address token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore,
        uint64 bridgeSafetyBufferCore
    ) external;

    /**
     * @notice Sets the parameters for a final token.
     * @dev This function deploys a new SwapHandler contract if one is not already set. If the final token
     * can't be used for account activation, the handler will be left unactivated and would need to be activated by the caller.
     * @param finalToken The address of the final token.
     * @param assetIndex The index of the asset in the Hyperliquid market.
     * @param isBuy Whether the final token is a buy or a sell.
     * @param feePpm The fee in parts per million.
     * @param suggestedDiscountBps The suggested slippage in basis points.
     * @param accountActivationFeeToken A token to pay account activation fee in. Only used if adding a new final token
     */
    function setFinalTokenInfo(
        address finalToken,
        uint32 assetIndex,
        bool isBuy,
        uint32 feePpm,
        uint32 suggestedDiscountBps,
        address accountActivationFeeToken
    ) external;

    /**
     * @notice Predicts the deterministic address of a SwapHandler for a given finalToken using CREATE2
     * @param finalToken The final token address
     * @return The predicted address of the SwapHandler
     */
    function predictSwapHandler(address finalToken) external view returns (address);

    /**
     * @notice Used for ad-hoc sends of sponsorship funds to associated SwapHandler @ HyperCore
     * @param token The final token for which we want to fund the SwapHandler
     * @param amount The amount to send
     */
    function sendSponsorshipFundsToSwapHandler(address token, uint256 amount) external;

    /**
     * @notice Sweeps ERC20 tokens from the contract
     * @param token The token address to sweep
     * @param amount The amount to sweep
     */
    function sweepErc20(address token, uint256 amount) external;

    /**
     * @notice Sweeps ERC20 tokens from the donation box
     * @param token The token address to sweep
     * @param amount The amount to sweep
     */
    function sweepErc20FromDonationBox(address token, uint256 amount) external;

    /**
     * @notice Sweeps ERC20 tokens from a SwapHandler
     * @param token The token address to sweep
     * @param amount The amount to sweep
     */
    function sweepERC20FromSwapHandler(address token, uint256 amount) external;

    /**
     * @notice Sweeps tokens from Core
     * @param token The token address
     * @param amount The amount to sweep in core units
     */
    function sweepOnCore(address token, uint64 amount) external;

    /**
     * @notice Sweeps tokens from Core from a SwapHandler
     * @param token The token address
     * @param amount The amount to sweep in core units
     */
    function sweepOnCoreFromSwapHandler(address token, uint64 amount) external;
}
