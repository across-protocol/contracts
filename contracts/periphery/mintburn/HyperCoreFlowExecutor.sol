//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { AuthorizedFundedFlow } from "./AuthorizedFundedFlow.sol";
import { HyperCoreFlowRoles } from "./HyperCoreFlowRoles.sol";
import { DonationBox } from "../../chain-adapters/DonationBox.sol";
import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { CoreTokenInfo } from "./Structs.sol";
import { FinalTokenInfo } from "./Structs.sol";
import { SwapHandler } from "./SwapHandler.sol";
import { BPS_SCALAR, BPS_DECIMALS } from "./Constants.sol";
import { CommonFlowParams } from "./Structs.sol";

// Note: v5 is necessary since v4 does not use ERC-7201.
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

/**
 * @title HyperCoreFlowExecutor
 * @notice Contract handling HyperCore interactions for transfer-to-core or swap-with-core actions after stablecoin bridge transactions
 * @dev This contract is designed to work with stablecoins. baseToken and every finalToken should all be stablecoins.
 *
 * @dev This contract is intended to be used exclusively via delegatecall from handler contracts.
 * Direct calls to this contract will produce incorrect results because functions rely on the
 * caller's context, including address(this) for calculations and storage layout from the
 * delegating contract.
 *
 * @custom:security-contact bugs@across.to
 */
contract HyperCoreFlowExecutor is AccessControlUpgradeable, AuthorizedFundedFlow, HyperCoreFlowRoles {
    using SafeERC20 for IERC20;

    // Common decimals scalars
    uint256 public constant PPM_DECIMALS = 6;
    uint256 public constant PPM_SCALAR = 10 ** PPM_DECIMALS;
    uint64 public constant ONEX1e8 = 10 ** 8;

    /// @notice The donation box contract.
    DonationBox public immutable donationBox;

    /// @notice All operations performed in this contract are relative to this baseToken
    address public immutable baseToken;

    /// @notice A struct used for storing state of a swap flow that has been initialized, but not yet finished
    struct SwapFlowState {
        address finalRecipient;
        address finalToken;
        uint64 minAmountToSend; // for sponsored: one to one, non-sponsored: one to one minus slippage
        uint64 maxAmountToSend; // for sponsored: one to one (from total bridged amt), for non-sponsored: one to one, less bridging fees incurred
        bool isSponsored;
        bool finalized;
    }

    /// @custom:storage-location erc7201:HyperCoreFlowExecutor.main
    struct MainStorage {
        /// @notice A mapping of token addresses to their core token info.
        mapping(address => CoreTokenInfo) coreTokenInfos;
        /// @notice A mapping of token address to additional relevan info for final tokens, like Hyperliquid market params
        mapping(address => FinalTokenInfo) finalTokenInfos;
        /// @notice The block number of the last funds pull action per final token: either as a part of finalizing pending swaps,
        /// or an admin funds pull
        mapping(address finalToken => uint256 lastPullFundsBlock) lastPullFundsBlock;
        /// @notice A mapping containing the pending state between initializing the swap flow and finalizing it
        mapping(bytes32 quoteNonce => SwapFlowState swap) swaps;
        /// @notice The cumulative amount of funds sponsored for each final token.
        mapping(address => uint256) cumulativeSponsoredAmount;
        /// @notice The cumulative amount of activation fees sponsored for each final token.
        mapping(address => uint256) cumulativeSponsoredActivationFee;
    }

    // keccak256(abi.encode(uint256(keccak256("erc7201:HyperCoreFlowExecutor.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MAIN_STORAGE_LOCATION = 0x6c70e510d36398bee89cc6e19ea6807a9915863d7d724712e0b3c15b01368b00;

    function _getMainStorage() private pure returns (MainStorage storage $) {
        assembly {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    /**************************************
     *            EVENTS               *
     **************************************/

    /**
     * @notice Emitted when the donation box is insufficient funds.
     * @param quoteNonce Unique identifier for this quote/transaction
     * @param token The token address that was requested
     * @param amount The amount requested from the donation box
     * @param balance The actual balance available in the donation box
     */
    event DonationBoxInsufficientFunds(bytes32 indexed quoteNonce, address token, uint256 amount, uint256 balance);

    /**
     * @notice Emitted whenever the account is not activated in the non-sponsored flow. We fall back to HyperEVM flow in that case
     * @param quoteNonce Unique identifier for this quote/transaction
     * @param user The address of the user whose account is not activated
     */
    event AccountNotActivated(bytes32 indexed quoteNonce, address user);

    /**
     * @notice Emitted when a simple transfer to core is executed.
     * @param quoteNonce Unique identifier for this quote/transaction
     * @param finalRecipient The address receiving the funds on HyperCore
     * @param finalToken The token address being transferred
     * @param evmAmountIn The amount received on HyperEVM (in finalToken)
     * @param bridgingFeesIncurred The bridging fees incurred (in finalToken)
     * @param evmAmountSponsored The amount sponsored from the donation box (in finalToken)
     */
    event SimpleTransferFlowCompleted(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // All amounts are in finalToken
        uint256 evmAmountIn,
        uint256 bridgingFeesIncurred,
        uint256 evmAmountSponsored
    );

    /**
     * @notice Emitted upon successful completion of fallback HyperEVM flow
     * @param quoteNonce Unique identifier for this quote/transaction
     * @param finalRecipient The address receiving the funds on HyperEVM
     * @param finalToken The token address being transferred
     * @param evmAmountIn The amount received on HyperEVM (in finalToken)
     * @param bridgingFeesIncurred The bridging fees incurred (in finalToken)
     * @param evmAmountSponsored The amount sponsored from the donation box (in finalToken)
     */
    event FallbackHyperEVMFlowCompleted(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // All amounts are in finalToken
        uint256 evmAmountIn,
        uint256 bridgingFeesIncurred,
        uint256 evmAmountSponsored
    );

    /**
     * @notice Emitted when a swap flow is initialized
     * @param quoteNonce Unique identifier for this quote/transaction
     * @param finalRecipient The address that will receive the swapped funds on HyperCore
     * @param finalToken The token address to swap to
     * @param evmAmountIn The amount received on HyperEVM (in baseToken)
     * @param bridgingFeesIncurred The bridging fees incurred (in baseToken)
     * @param coreAmountIn The amount sent to HyperCore (in finalToken)
     * @param minAmountToSend Minimum amount to send to user after swap (in finalToken)
     * @param maxAmountToSend Maximum amount to send to user after swap (in finalToken)
     */
    event SwapFlowInitialized(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // In baseToken
        uint256 evmAmountIn,
        uint256 bridgingFeesIncurred,
        // In finalToken
        uint256 coreAmountIn,
        uint64 minAmountToSend,
        uint64 maxAmountToSend
    );

    /**
     * @notice Emitted when a swap flow is finalized
     * @param quoteNonce Unique identifier for this quote/transaction
     * @param finalRecipient The address that received the swapped funds on HyperCore
     * @param finalToken The token address that was swapped to
     * @param totalSent Total amount sent to the final recipient on HyperCore (in finalToken)
     * @param evmAmountSponsored The amount sponsored from the donation box (in EVM finalToken)
     */
    event SwapFlowFinalized(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // In finalToken
        uint64 totalSent,
        // In EVM finalToken
        uint256 evmAmountSponsored
    );

    /**
     * @notice Emitted upon cancelling a Limit order
     * @param token The token address for which the limit order was placed
     * @param cloid Client order ID of the cancelled limit order
     */
    event CancelledLimitOrder(address indexed token, uint128 indexed cloid);

    /**
     * @notice Emitted upon submitting a Limit order
     * @param token The token address for which the limit order is placed
     * @param priceX1e8 The limit order price (scaled by 1e8)
     * @param sizeX1e8 The limit order size (scaled by 1e8)
     * @param cloid Client order ID of the submitted limit order
     */
    event SubmittedLimitOrder(address indexed token, uint64 priceX1e8, uint64 sizeX1e8, uint128 indexed cloid);

    /**
     * @notice Emitted when we have to fall back from the swap flow because it's too expensive (either to sponsor or the slippage is too big)
     * @param quoteNonce Unique identifier for this quote/transaction
     * @param finalToken The token address that was intended to be swapped to
     * @param estBpsSlippage Estimated slippage in basis points
     * @param maxAllowableBpsSlippage Maximum allowable slippage in basis points
     */
    event SwapFlowTooExpensive(
        bytes32 indexed quoteNonce,
        address indexed finalToken,
        uint256 estBpsSlippage,
        uint256 maxAllowableBpsSlippage
    );

    /**
     * @notice Emitted when we can't bridge some token from HyperEVM to HyperCore
     * @param quoteNonce Unique identifier for this quote/transaction
     * @param token The token address that is unsafe to bridge
     * @param amount The amount that was attempted to be bridged
     */
    event UnsafeToBridge(bytes32 indexed quoteNonce, address indexed token, uint64 amount);

    /**
     * @notice Emitted whenever donationBox funds are used for activating a user account
     * @param quoteNonce Unique identifier for this quote/transaction
     * @param finalRecipient The address of the user whose account is being activated
     * @param fundingToken The token used to fund the account activation
     * @param evmAmountSponsored The amount sponsored for activation (in EVM token)
     */
    event SponsoredAccountActivation(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed fundingToken,
        uint256 evmAmountSponsored
    );

    /**
     * @notice Emitted whenever a new CoreTokenInfo is configured
     * @param token The token address being configured
     * @param coreIndex The index of the token on HyperCore
     * @param canBeUsedForAccountActivation Whether this token can be used to pay for account activation
     * @param accountActivationFeeCore The account activation fee amount (in Core token units)
     * @param bridgeSafetyBufferCore The safety buffer for bridging (in Core token units)
     */
    event SetCoreTokenInfo(
        address indexed token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore,
        uint64 bridgeSafetyBufferCore
    );

    /// @notice Emitted whenever a new FinalTokenInfo is configured
    event SetFinalTokenInfo(
        address indexed token,
        uint32 spotIndex,
        bool isBuy,
        uint32 feePpm,
        address indexed swapHandler,
        uint32 suggestedFeeDiscountBps
    );

    /**
     * @notice Emitted when we do an ad-hoc send of sponsorship funds to one of the Swap Handlers
     * @param token The token address being sent to the swap handler
     * @param evmAmountSponsored The amount sponsored from the donation box (in EVM token)
     */
    event SentSponsorshipFundsToSwapHandler(address indexed token, uint256 evmAmountSponsored);

    /**************************************
     *            ERRORS               *
     **************************************/

    /// @notice Thrown when an attempt to finalize a non-existing swap is made
    error SwapDoesNotExist();

    /// @notice Thrown when an attemp to finalize an already finalized swap is made
    error SwapAlreadyFinalized();

    /// @notice Thrown when trying to finalize a quoteNonce, calling a finalizeSwapFlows with an incorrect token
    error WrongSwapFinalizationToken(bytes32 quoteNonce);

    /// @notice Emitted when we're inside the sponsored flow and a user doesn't have a HyperCore account activated. The
    /// bot should activate user's account first by calling `activateUserAccount`
    error AccountNotActivatedError(address user);

    /// @notice Thrown when we can't bridge some token from HyperEVM to HyperCore
    error UnsafeToBridgeError(address token, uint64 amount);

    /**************************************
     *            MODIFIERS               *
     **************************************/

    modifier onlyExistingCoreToken(address evmTokenAddress) {
        _getExistingCoreTokenInfo(evmTokenAddress);
        _;
    }

    /// @notice Reverts if the token is not configured
    function _getExistingCoreTokenInfo(
        address evmTokenAddress
    ) internal view returns (CoreTokenInfo memory coreTokenInfo) {
        coreTokenInfo = _getMainStorage().coreTokenInfos[evmTokenAddress];
        require(
            coreTokenInfo.tokenInfo.evmContract != address(0) && coreTokenInfo.tokenInfo.weiDecimals != 0,
            "CoreTokenInfo not set"
        );
    }

    /// @notice Reverts if the token is not configured
    function _getExistingFinalTokenInfo(
        address evmTokenAddress
    ) internal view returns (FinalTokenInfo memory finalTokenInfo) {
        finalTokenInfo = _getMainStorage().finalTokenInfos[evmTokenAddress];
        require(address(finalTokenInfo.swapHandler) != address(0), "FinalTokenInfo not set");
    }

    /**
     *
     * @param _donationBox Sponsorship funds live here
     * @param _baseToken Main token used with this Forwarder
     */
    constructor(address _donationBox, address _baseToken) {
        // Set immutable variables only
        donationBox = DonationBox(_donationBox);
        baseToken = _baseToken;
    }

    /****************************************
     *            VIEW FUNCTIONS           *
     **************************************/

    /**
     * @notice Returns the core token info for a given token address.
     * @param token The token address.
     * @return The core token info for the given token address.
     */
    function coreTokenInfos(address token) external view returns (CoreTokenInfo memory) {
        return _getMainStorage().coreTokenInfos[token];
    }

    /**
     * @notice Returns the final token info for a given token address.
     * @param token The token address.
     * @return The final token info for the given token address.
     */
    function finalTokenInfos(address token) external view returns (FinalTokenInfo memory) {
        return _getMainStorage().finalTokenInfos[token];
    }

    /**
     * @notice Returns the block number of the last time funds were pulled from the donation box.
     * @param token The token address.
     * @return The block number of the last time funds were pulled from the donation box for the given token address.
     */
    function lastPullFundsBlock(address token) external view returns (uint256) {
        return _getMainStorage().lastPullFundsBlock[token];
    }

    /**
     * @notice Returns the swap info for a given quote nonce.
     * @param quoteNonce The quote nonce.
     * @return The swap info for the given quote nonce.
     */
    function swaps(bytes32 quoteNonce) external view returns (SwapFlowState memory) {
        return _getMainStorage().swaps[quoteNonce];
    }

    /**
     * @notice Returns the cumulative sponsored amount for a given token address.
     * @param token The token address.
     * @return The cumulative sponsored amount for the given token address.
     */
    function cumulativeSponsoredAmount(address token) external view returns (uint256) {
        return _getMainStorage().cumulativeSponsoredAmount[token];
    }

    /**
     * @notice Returns the cumulative sponsored activation fee for a given token address.
     * @param token The token address.
     * @return The cumulative sponsored activation fee for the given token address.
     */
    function cumulativeSponsoredActivationFee(address token) external view returns (uint256) {
        return _getMainStorage().cumulativeSponsoredActivationFee[token];
    }

    /**************************************
     *      CONFIGURATION FUNCTIONS       *
     **************************************/

    /**
     * @notice Set or update information for the token to use it in this contract
     * @dev To be able to use the token in the swap flow, FinalTokenInfo has to be set as well
     * @dev Setting core token info to incorrect values can lead to loss of funds. Should NEVER be unset while the
     * finalTokenParams are not unset
     * @param token The token address being configured
     * @param coreIndex The index of the token on HyperCore
     * @param canBeUsedForAccountActivation Whether this token can be used to pay for account activation
     * @param accountActivationFeeCore The account activation fee amount (in Core token units)
     * @param bridgeSafetyBufferCore The safety buffer for bridging (in Core token units)
     */
    function setCoreTokenInfo(
        address token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore,
        uint64 bridgeSafetyBufferCore
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCoreTokenInfo(
            token,
            coreIndex,
            canBeUsedForAccountActivation,
            accountActivationFeeCore,
            bridgeSafetyBufferCore
        );
    }

    /**
     * @notice Sets the parameters for a final token.
     * @dev This function deploys a new SwapHandler contract if one is not already set. If the final token
     * can't be used for account activation, the handler will be left unactivated and would need to be activated by the caller.
     * @param finalToken The address of the final token.
     * @param spotIndex The index of the asset in the Hyperliquid market.
     * @param isBuy Whether the final token is a buy or a sell.
     * @param feePpm The fee in parts per million.
     * @param suggestedDiscountBps The suggested slippage in basis points.
     */
    function setFinalTokenInfo(
        address finalToken,
        uint32 spotIndex,
        bool isBuy,
        uint32 feePpm,
        uint32 suggestedDiscountBps
    ) external onlyExistingCoreToken(finalToken) onlyRole(DEFAULT_ADMIN_ROLE) {
        MainStorage storage $ = _getMainStorage();
        SwapHandler swapHandler = $.finalTokenInfos[finalToken].swapHandler;
        if (address(swapHandler) == address(0)) {
            bytes32 salt = _swapHandlerSalt(finalToken);
            swapHandler = new SwapHandler{ salt: salt }();
        }

        $.finalTokenInfos[finalToken] = FinalTokenInfo({
            spotIndex: spotIndex,
            isBuy: isBuy,
            feePpm: feePpm,
            swapHandler: swapHandler,
            suggestedDiscountBps: suggestedDiscountBps
        });

        // We don't allow SwapHandler accounts to be uninitiated. That could lead to loss of funds. They instead should
        // be pre-funded using `predictSwapHandler` to predict their address
        require(HyperCoreLib.coreUserExists(address(swapHandler)), "SwapHandler @ core doesn't exist");

        emit SetFinalTokenInfo(finalToken, spotIndex, isBuy, feePpm, address(swapHandler), suggestedDiscountBps);
    }

    /**
     * @notice Predicts the deterministic address of a SwapHandler for a given finalToken using CREATE2
     * @param finalToken The token address for which to predict the SwapHandler address
     * @return The predicted address of the SwapHandler contract
     */
    function predictSwapHandler(address finalToken) public view returns (address) {
        bytes32 salt = _swapHandlerSalt(finalToken);
        bytes32 initCodeHash = keccak256(type(SwapHandler).creationCode);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice Returns the salt to use when creating a SwapHandler via CREATE2
    function _swapHandlerSalt(address finalToken) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), finalToken));
    }

    /**************************************
     *            FLOW FUNCTIONS          *
     **************************************/

    /**
     * @notice External entrypoint to execute flow when called via delegatecall from a handler. Works with params
     * checked by a handler. Params authorization by a handler is enforced via `onlyAuthorizedFlow` modifier
     */
    function executeFlow(CommonFlowParams memory params, uint256 maxUserSlippageBps) external onlyAuthorizedFlow {
        if (params.finalToken == baseToken) {
            _executeSimpleTransferFlow(params);
        } else {
            _initiateSwapFlow(params, maxUserSlippageBps);
        }
    }

    /// @notice External entrypoint to execute simple transfer flow (see `executeFlow` comment for details)
    function executeSimpleTransferFlow(CommonFlowParams memory params) external onlyAuthorizedFlow {
        _executeSimpleTransferFlow(params);
    }

    /// @notice External entrypoint to execute fallback evm flow (see `executeFlow` comment for details)
    function fallbackHyperEVMFlow(CommonFlowParams memory params) external onlyAuthorizedFlow {
        _fallbackHyperEVMFlow(params);
    }

    /// @notice Execute a simple transfer flow in which we transfer `finalToken` to the user on HyperCore after receiving
    /// an amount of finalToken from the user on HyperEVM
    function _executeSimpleTransferFlow(CommonFlowParams memory params) internal {
        address finalToken = params.finalToken;
        MainStorage storage $ = _getMainStorage();
        CoreTokenInfo memory coreTokenInfo = $.coreTokenInfos[finalToken];

        // Check account activation
        if (!HyperCoreLib.coreUserExists(params.finalRecipient)) {
            if (params.maxBpsToSponsor > 0) {
                revert AccountNotActivatedError(params.finalRecipient);
            } else {
                emit AccountNotActivated(params.quoteNonce, params.finalRecipient);
                _fallbackHyperEVMFlow(params);
                return;
            }
        }

        // Calculate sponsorship amount in scope
        uint256 amountToSponsor;
        {
            uint256 maxEvmAmountToSponsor = ((params.amountInEVM + params.extraFeesIncurred) * params.maxBpsToSponsor) /
                BPS_SCALAR;
            amountToSponsor = params.extraFeesIncurred;
            if (amountToSponsor > maxEvmAmountToSponsor) {
                amountToSponsor = maxEvmAmountToSponsor;
            }

            if (amountToSponsor > 0) {
                if (!_availableInDonationBox(params.quoteNonce, finalToken, amountToSponsor)) {
                    // If the full amount is not available in the donation box, use the balance of the token in the donation box
                    amountToSponsor = IERC20(finalToken).balanceOf(address(donationBox));
                }
            }
        }

        // Calculate quoted amounts and check safety
        uint256 quotedEvmAmount;
        uint64 quotedCoreAmount;
        {
            uint256 finalAmount = params.amountInEVM + amountToSponsor;
            (quotedEvmAmount, quotedCoreAmount) = HyperCoreLib.maximumEVMSendAmountToAmounts(
                finalAmount,
                coreTokenInfo.tokenInfo.evmExtraWeiDecimals
            );
            // If there are no funds left on the destination side of the bridge, the funds will be lost in the
            // bridge. We check send safety via `isCoreAmountSafeToBridge`
            if (
                !HyperCoreLib.isCoreAmountSafeToBridge(
                    coreTokenInfo.coreIndex,
                    quotedCoreAmount,
                    coreTokenInfo.bridgeSafetyBufferCore
                )
            ) {
                // If the amount is not safe to bridge because the bridge doesn't have enough liquidity,
                // fall back to sending user funds on HyperEVM.
                _fallbackHyperEVMFlow(params);
                emit UnsafeToBridge(params.quoteNonce, finalToken, quotedCoreAmount);
                return;
            }
        }

        if (amountToSponsor > 0) {
            // This will succeed because we checked the balance earlier
            donationBox.withdraw(IERC20(finalToken), amountToSponsor);
        }

        $.cumulativeSponsoredAmount[finalToken] += amountToSponsor;

        // There is a very slim change that someone is sending > buffer amount in the same EVM block and the balance of
        // the bridge is not enough to cover our transfer, so the funds are lost.
        HyperCoreLib.transferERC20EVMToCore(
            finalToken,
            coreTokenInfo.coreIndex,
            params.finalRecipient,
            quotedEvmAmount,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        emit SimpleTransferFlowCompleted(
            params.quoteNonce,
            params.finalRecipient,
            finalToken,
            params.amountInEVM,
            params.extraFeesIncurred,
            amountToSponsor
        );
    }

    /**
     * @notice Initiates the swap flow. Sends the funds received on EVM side over to a SwapHandler corresponding to a
     * finalToken. This is the first leg of the swap flow. Next, the bot should submit a limit order through a `submitLimitOrderFromBot`
     * function, and then settle the flow via a `finalizeSwapFlows` function
     * @dev Only works for stable -> stable swap flows (or equivalent token flows. Price between tokens is supposed to be approximately one to one)
     * @param maxUserSlippageBps Describes a configured user setting. Slippage here is wrt the one to one exchange
     */
    function _initiateSwapFlow(CommonFlowParams memory params, uint256 maxUserSlippageBps) internal {
        address initialToken = baseToken;

        // Check account activation
        if (!HyperCoreLib.coreUserExists(params.finalRecipient)) {
            if (params.maxBpsToSponsor > 0) {
                revert AccountNotActivatedError(params.finalRecipient);
            } else {
                emit AccountNotActivated(params.quoteNonce, params.finalRecipient);
                params.finalToken = initialToken;
                _fallbackHyperEVMFlow(params);
                return;
            }
        }

        MainStorage storage $ = _getMainStorage();
        CoreTokenInfo memory initialCoreTokenInfo = $.coreTokenInfos[initialToken];
        CoreTokenInfo memory finalCoreTokenInfo = $.coreTokenInfos[params.finalToken];
        FinalTokenInfo memory finalTokenInfo = _getExistingFinalTokenInfo(params.finalToken);

        // Calculate limit order amounts and check if feasible
        uint64 minAllowableAmountToForwardCore;
        uint64 maxAllowableAmountToForwardCore;
        // Estimated slippage in ppm, as compared to a one-to-one totalBridgedAmount -> finalAmount conversion
        uint256 estSlippagePpm;
        {
            // In finalToken
            (minAllowableAmountToForwardCore, maxAllowableAmountToForwardCore) = _calcAllowableAmtsSwapFlow(
                params.amountInEVM,
                params.extraFeesIncurred,
                initialCoreTokenInfo,
                finalCoreTokenInfo,
                params.maxBpsToSponsor > 0,
                maxUserSlippageBps
            );

            uint64 approxExecutionPriceX1e8 = _getApproxRealizedPrice(
                finalTokenInfo,
                finalCoreTokenInfo,
                initialCoreTokenInfo
            );
            uint256 maxAllowableBpsDeviation = params.maxBpsToSponsor > 0 ? params.maxBpsToSponsor : maxUserSlippageBps;
            if (finalTokenInfo.isBuy) {
                if (approxExecutionPriceX1e8 < ONEX1e8) {
                    estSlippagePpm = 0;
                } else {
                    // ceil
                    estSlippagePpm = ((approxExecutionPriceX1e8 - ONEX1e8) * PPM_SCALAR + (ONEX1e8 - 1)) / ONEX1e8;
                }
            } else {
                if (approxExecutionPriceX1e8 > ONEX1e8) {
                    estSlippagePpm = 0;
                } else {
                    // ceil
                    estSlippagePpm = ((ONEX1e8 - approxExecutionPriceX1e8) * PPM_SCALAR + (ONEX1e8 - 1)) / ONEX1e8;
                }
            }
            // Add `extraFeesIncurred` to "slippage from one to one"
            estSlippagePpm +=
                (params.extraFeesIncurred * PPM_SCALAR + (params.amountInEVM + params.extraFeesIncurred) - 1) /
                (params.amountInEVM + params.extraFeesIncurred);

            if (estSlippagePpm > maxAllowableBpsDeviation * 10 ** (PPM_DECIMALS - BPS_DECIMALS)) {
                emit SwapFlowTooExpensive(
                    params.quoteNonce,
                    params.finalToken,
                    (estSlippagePpm + 10 ** (PPM_DECIMALS - BPS_DECIMALS) - 1) / 10 ** (PPM_DECIMALS - BPS_DECIMALS),
                    maxAllowableBpsDeviation
                );
                params.finalToken = initialToken;
                _executeSimpleTransferFlow(params);
                return;
            }
        }

        (uint256 tokensToSendEvm, uint64 coreAmountIn) = HyperCoreLib.maximumEVMSendAmountToAmounts(
            params.amountInEVM,
            initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        // Check that we can safely bridge to HCore (for the trade amount actually needed)
        bool isSafeToBridgeMainToken = HyperCoreLib.isCoreAmountSafeToBridge(
            initialCoreTokenInfo.coreIndex,
            coreAmountIn,
            initialCoreTokenInfo.bridgeSafetyBufferCore
        );

        if (!isSafeToBridgeMainToken) {
            emit UnsafeToBridge(params.quoteNonce, initialToken, coreAmountIn);
            params.finalToken = initialToken;
            _fallbackHyperEVMFlow(params);
            return;
        }

        // Finalize swap flow setup by updating state and funding SwapHandler
        // State changes
        $.swaps[params.quoteNonce] = SwapFlowState({
            finalRecipient: params.finalRecipient,
            finalToken: params.finalToken,
            minAmountToSend: minAllowableAmountToForwardCore,
            maxAmountToSend: maxAllowableAmountToForwardCore,
            isSponsored: params.maxBpsToSponsor > 0,
            finalized: false
        });

        emit SwapFlowInitialized(
            params.quoteNonce,
            params.finalRecipient,
            params.finalToken,
            params.amountInEVM,
            params.extraFeesIncurred,
            coreAmountIn,
            minAllowableAmountToForwardCore,
            maxAllowableAmountToForwardCore
        );

        // Send amount received from user to a corresponding SwapHandler
        SwapHandler swapHandler = finalTokenInfo.swapHandler;
        IERC20(initialToken).safeTransfer(address(swapHandler), tokensToSendEvm);
        swapHandler.transferFundsToSelfOnCore(
            initialToken,
            initialCoreTokenInfo.coreIndex,
            tokensToSendEvm,
            initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
    }

    /**
     * @notice Finalizes multiple swap flows associated with a final token, subject to the L1 Hyperliquid balance
     * @dev Caller is responsible for providing correct limitOrderOutput amounts per assosicated swap flow. The caller
     * has to estimate how much final tokens it received on core based on the input of the corresponding quote nonce
     * swap flow
     * @param finalToken The token address for the swaps being finalized
     * @param quoteNonces Array of quote nonces identifying the swap flows to finalize
     * @param limitOrderOuts Array of limit order output amounts corresponding to each quote nonce
     * @return finalized The number of swap flows that were successfully finalized
     */
    function finalizeSwapFlows(
        address finalToken,
        bytes32[] calldata quoteNonces,
        uint64[] calldata limitOrderOuts
    ) external onlyRole(PERMISSIONED_BOT_ROLE) returns (uint256 finalized) {
        MainStorage storage $ = _getMainStorage();
        require(quoteNonces.length == limitOrderOuts.length, "length");
        require($.lastPullFundsBlock[finalToken] < block.number, "too soon");

        CoreTokenInfo memory finalCoreTokenInfo = _getExistingCoreTokenInfo(finalToken);
        FinalTokenInfo memory finalTokenInfo = _getExistingFinalTokenInfo(finalToken);

        uint64 availableBalance = HyperCoreLib.spotBalance(
            address(finalTokenInfo.swapHandler),
            finalCoreTokenInfo.coreIndex
        );
        uint64 totalAdditionalToSend = 0;
        for (; finalized < quoteNonces.length; ++finalized) {
            bool success;
            uint64 additionalToSend;
            (success, additionalToSend, availableBalance) = _finalizeSingleSwap(
                quoteNonces[finalized],
                limitOrderOuts[finalized],
                finalCoreTokenInfo,
                finalTokenInfo.swapHandler,
                finalToken,
                availableBalance
            );
            if (!success) {
                break;
            }
            totalAdditionalToSend += additionalToSend;
        }

        if (finalized > 0) {
            $.lastPullFundsBlock[finalToken] = block.number;
        } else {
            return 0;
        }

        if (totalAdditionalToSend > 0) {
            (uint256 totalAdditionalToSendEVM, uint64 totalAdditionalReceivedCore) = HyperCoreLib
                .minimumCoreReceiveAmountToAmounts(
                    totalAdditionalToSend,
                    finalCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
                );

            if (
                !HyperCoreLib.isCoreAmountSafeToBridge(
                    finalCoreTokenInfo.coreIndex,
                    totalAdditionalReceivedCore,
                    finalCoreTokenInfo.bridgeSafetyBufferCore
                )
            ) {
                // We expect this situation to be so rare and / or intermittend that we're willing to rely on admin to sweep the funds if this leads to
                // swaps being impossible to finalize
                revert UnsafeToBridgeError(finalToken, totalAdditionalToSend);
            }

            $.cumulativeSponsoredAmount[finalToken] += totalAdditionalToSendEVM;

            // ! Notice: as per HyperEVM <> HyperCore rules, this amount will land on HyperCore *before* all of the core > core sends get executed
            // Get additional amount to send from donation box, and send it to self on core
            donationBox.withdraw(IERC20(finalToken), totalAdditionalToSendEVM);
            IERC20(finalToken).safeTransfer(address(finalTokenInfo.swapHandler), totalAdditionalToSendEVM);
            finalTokenInfo.swapHandler.transferFundsToSelfOnCore(
                finalToken,
                finalCoreTokenInfo.coreIndex,
                totalAdditionalToSendEVM,
                finalCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
            );
        }
    }

    /// @notice Finalizes a single swap flow, sending the tokens to user on core. Relies on caller to send the `additionalToSend`
    function _finalizeSingleSwap(
        bytes32 quoteNonce,
        uint64 limitOrderOut,
        CoreTokenInfo memory finalCoreTokenInfo,
        SwapHandler swapHandler,
        address finalToken,
        uint64 availableBalance
    ) internal returns (bool success, uint64 additionalToSend, uint64 balanceRemaining) {
        SwapFlowState storage swap = _getMainStorage().swaps[quoteNonce];
        if (swap.finalRecipient == address(0)) revert SwapDoesNotExist();
        if (swap.finalized) revert SwapAlreadyFinalized();
        if (swap.finalToken != finalToken) revert WrongSwapFinalizationToken(quoteNonce);

        uint64 totalToSend;
        (totalToSend, additionalToSend) = _calcSwapFlowSendAmounts(
            limitOrderOut,
            swap.minAmountToSend,
            swap.maxAmountToSend,
            swap.isSponsored
        );

        // `additionalToSend` will land on HCore before this core > core send will need to be executed
        balanceRemaining = availableBalance + additionalToSend;
        if (totalToSend > balanceRemaining) {
            return (false, 0, availableBalance);
        }

        swap.finalized = true;
        success = true;
        balanceRemaining -= totalToSend;

        (uint256 additionalToSendEVM, ) = HyperCoreLib.minimumCoreReceiveAmountToAmounts(
            additionalToSend,
            finalCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        swapHandler.transferFundsToUserOnCore(finalCoreTokenInfo.coreIndex, swap.finalRecipient, totalToSend);
        emit SwapFlowFinalized(quoteNonce, swap.finalRecipient, swap.finalToken, totalToSend, additionalToSendEVM);
    }

    /// @notice Forwards `amount` plus potential sponsorship funds (for bridging fee) to user on HyperEVM
    function _fallbackHyperEVMFlow(CommonFlowParams memory params) internal {
        uint256 maxEvmAmountToSponsor = ((params.amountInEVM + params.extraFeesIncurred) * params.maxBpsToSponsor) /
            BPS_SCALAR;
        uint256 sponsorshipFundsToForward = params.extraFeesIncurred > maxEvmAmountToSponsor
            ? maxEvmAmountToSponsor
            : params.extraFeesIncurred;

        if (!_availableInDonationBox(params.quoteNonce, params.finalToken, sponsorshipFundsToForward)) {
            sponsorshipFundsToForward = 0;
        }
        if (sponsorshipFundsToForward > 0) {
            donationBox.withdraw(IERC20(params.finalToken), sponsorshipFundsToForward);
        }
        uint256 totalAmountToForward = params.amountInEVM + sponsorshipFundsToForward;
        IERC20(params.finalToken).safeTransfer(params.finalRecipient, totalAmountToForward);
        _getMainStorage().cumulativeSponsoredAmount[params.finalToken] += sponsorshipFundsToForward;
        emit FallbackHyperEVMFlowCompleted(
            params.quoteNonce,
            params.finalRecipient,
            params.finalToken,
            params.amountInEVM,
            params.extraFeesIncurred,
            sponsorshipFundsToForward
        );
    }

    /**
     * @notice Activates a user account on Core by funding the account activation fee.
     * @param quoteNonce The nonce of the quote that is used to identify the user.
     * @param finalRecipient The address of the recipient of the funds.
     * @param fundingToken The address of the token that is used to fund the account activation fee.
     */
    function activateUserAccount(
        bytes32 quoteNonce,
        address finalRecipient,
        address fundingToken
    ) external onlyRole(PERMISSIONED_BOT_ROLE) {
        CoreTokenInfo memory coreTokenInfo = _getExistingCoreTokenInfo(fundingToken);
        bool coreUserExists = HyperCoreLib.coreUserExists(finalRecipient);
        require(!coreUserExists, "Can't fund account activation for existing user");
        require(coreTokenInfo.canBeUsedForAccountActivation, "Token can't be used for this");

        // +1 wei for a spot send
        uint64 totalBalanceRequiredToActivate = coreTokenInfo.accountActivationFeeCore + 1;
        (uint256 evmAmountToSend, ) = HyperCoreLib.minimumCoreReceiveAmountToAmounts(
            totalBalanceRequiredToActivate,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        bool safeToBridge = HyperCoreLib.isCoreAmountSafeToBridge(
            coreTokenInfo.coreIndex,
            totalBalanceRequiredToActivate,
            coreTokenInfo.bridgeSafetyBufferCore
        );
        require(safeToBridge, "Not safe to bridge");
        _getMainStorage().cumulativeSponsoredActivationFee[fundingToken] += evmAmountToSend;

        // donationBox @ evm -> Handler @ evm
        donationBox.withdraw(IERC20(fundingToken), evmAmountToSend);
        // Handler @ evm -> Handler @ core
        HyperCoreLib.transferERC20EVMToSelfOnCore(
            fundingToken,
            coreTokenInfo.coreIndex,
            evmAmountToSend,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
        // The total balance withdrawn from Handler @ Core for this operation is activationFee + amountSent, so we set
        // amountSent to 1 wei to only activate the account
        // Handler @ core -> finalRecipient @ core
        HyperCoreLib.transferERC20CoreToCore(coreTokenInfo.coreIndex, finalRecipient, 1);

        emit SponsoredAccountActivation(quoteNonce, finalRecipient, fundingToken, evmAmountToSend);
    }

    /**
     * @notice Cancells a pending limit order by `cloid` with an intention to submit a new limit order in its place. To
     * be used for stale limit orders to speed up executing user transactions
     * @param finalToken The token address for which the limit order was placed
     * @param cloid Client order ID of the limit order to cancel
     */
    function cancelLimitOrderByCloid(address finalToken, uint128 cloid) external onlyRole(PERMISSIONED_BOT_ROLE) {
        FinalTokenInfo memory finalTokenInfo = _getExistingFinalTokenInfo(finalToken);
        finalTokenInfo.swapHandler.cancelOrderByCloid(finalTokenInfo.spotIndex, cloid);

        emit CancelledLimitOrder(finalToken, cloid);
    }

    function submitLimitOrderFromBot(
        address finalToken,
        uint64 priceX1e8,
        uint64 sizeX1e8,
        uint128 cloid
    ) external onlyRole(PERMISSIONED_BOT_ROLE) {
        FinalTokenInfo memory finalTokenInfo = _getExistingFinalTokenInfo(finalToken);
        finalTokenInfo.swapHandler.submitSpotLimitOrder(finalTokenInfo, priceX1e8, sizeX1e8, cloid);

        emit SubmittedLimitOrder(finalToken, priceX1e8, sizeX1e8, cloid);
    }

    function _setCoreTokenInfo(
        address token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore,
        uint64 bridgeSafetyBufferCore
    ) internal {
        HyperCoreLib.TokenInfo memory tokenInfo = HyperCoreLib.tokenInfo(coreIndex);

        (uint256 accountActivationFeeEVM, ) = HyperCoreLib.minimumCoreReceiveAmountToAmounts(
            accountActivationFeeCore,
            tokenInfo.evmExtraWeiDecimals
        );

        _getMainStorage().coreTokenInfos[token] = CoreTokenInfo({
            tokenInfo: tokenInfo,
            coreIndex: coreIndex,
            canBeUsedForAccountActivation: canBeUsedForAccountActivation,
            accountActivationFeeEVM: accountActivationFeeEVM,
            accountActivationFeeCore: accountActivationFeeCore,
            bridgeSafetyBufferCore: bridgeSafetyBufferCore
        });

        emit SetCoreTokenInfo(
            token,
            coreIndex,
            canBeUsedForAccountActivation,
            accountActivationFeeCore,
            bridgeSafetyBufferCore
        );
    }

    /**
     * @notice Used for ad-hoc sends of sponsorship funds to associated SwapHandler @ HyperCore
     * @param token The final token for which we want to fund the SwapHandler
     * @param amount The amount of tokens to send to the SwapHandler
     */
    function sendSponsorshipFundsToSwapHandler(address token, uint256 amount) external onlyRole(PERMISSIONED_BOT_ROLE) {
        CoreTokenInfo memory coreTokenInfo = _getExistingCoreTokenInfo(token);
        FinalTokenInfo memory finalTokenInfo = _getExistingFinalTokenInfo(token);
        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = HyperCoreLib.maximumEVMSendAmountToAmounts(
            amount,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
        if (
            !HyperCoreLib.isCoreAmountSafeToBridge(
                coreTokenInfo.coreIndex,
                amountCoreToReceive,
                coreTokenInfo.bridgeSafetyBufferCore
            )
        ) {
            revert UnsafeToBridgeError(token, amountCoreToReceive);
        }

        _getMainStorage().cumulativeSponsoredAmount[token] += amountEVMToSend;

        emit SentSponsorshipFundsToSwapHandler(token, amountEVMToSend);

        donationBox.withdraw(IERC20(token), amountEVMToSend);
        IERC20(token).safeTransfer(address(finalTokenInfo.swapHandler), amountEVMToSend);
        finalTokenInfo.swapHandler.transferFundsToSelfOnCore(
            token,
            coreTokenInfo.coreIndex,
            amountEVMToSend,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
    }

    /// @notice Checks if `amount` of `token` is available to withdraw from donationBox
    function _availableInDonationBox(
        bytes32 quoteNonce,
        address token,
        uint256 amount
    ) internal returns (bool available) {
        uint256 balance = IERC20(token).balanceOf(address(donationBox));
        available = balance >= amount;
        if (!available) {
            emit DonationBoxInsufficientFunds(quoteNonce, token, amount, balance);
        }
    }

    function _calcAllowableAmtsSwapFlow(
        uint256 amount,
        uint256 extraFeesIncurred,
        CoreTokenInfo memory initialCoreTokenInfo,
        CoreTokenInfo memory finalCoreTokenInfo,
        bool isSponsoredFlow,
        uint256 maxUserSlippageBps
    ) internal pure returns (uint64 minAllowableAmountToForwardCore, uint64 maxAllowableAmountToForwardCore) {
        (, uint64 feelessAmountCoreInitialToken) = HyperCoreLib.maximumEVMSendAmountToAmounts(
            amount + extraFeesIncurred,
            initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
        uint64 feelessAmountCoreFinalToken = HyperCoreLib.convertCoreDecimalsSimple(
            feelessAmountCoreInitialToken,
            initialCoreTokenInfo.tokenInfo.weiDecimals,
            finalCoreTokenInfo.tokenInfo.weiDecimals
        );
        if (isSponsoredFlow) {
            minAllowableAmountToForwardCore = feelessAmountCoreFinalToken;
            maxAllowableAmountToForwardCore = feelessAmountCoreFinalToken;
        } else {
            minAllowableAmountToForwardCore = uint64(
                (feelessAmountCoreFinalToken * (BPS_SCALAR - maxUserSlippageBps)) / BPS_SCALAR
            );
            maxAllowableAmountToForwardCore = feelessAmountCoreFinalToken;
        }
    }

    /**
     * @return totalToSend What we will forward to user on HCore
     * @return additionalToSend What we will send from donationBox right now
     */
    function _calcSwapFlowSendAmounts(
        uint64 limitOrderOut,
        uint64 minAmountToSend,
        uint64 maxAmountToSend,
        bool isSponsored
    ) internal pure returns (uint64 totalToSend, uint64 additionalToSend) {
        if (isSponsored) {
            // `minAmountToSend` is equal to `maxAmountToSend` for the sponsored flow
            totalToSend = minAmountToSend;
            additionalToSend = totalToSend > limitOrderOut ? totalToSend - limitOrderOut : 0;
        } else {
            additionalToSend = limitOrderOut < minAmountToSend ? minAmountToSend - limitOrderOut : 0;
            uint64 proposedToSend = limitOrderOut + additionalToSend;
            totalToSend = proposedToSend > maxAmountToSend ? maxAmountToSend : proposedToSend;
        }
    }

    /// @notice Reads the current spot price from HyperLiquid and applies a configured suggested discount for faster execution
    /// @dev Includes HyperLiquid fees
    function _getApproxRealizedPrice(
        FinalTokenInfo memory finalTokenInfo,
        CoreTokenInfo memory finalCoreTokenInfo,
        CoreTokenInfo memory initialCoreTokenInfo
    ) internal view returns (uint64 limitPriceX1e8) {
        uint256 spotPxRaw = HyperCoreLib.spotPx(finalTokenInfo.spotIndex);
        // Convert to 10 ** 8 precision (https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore)
        // `szDecimals` of the base aseet for spot market
        uint8 additionalPowersOf10 = finalTokenInfo.isBuy
            ? finalCoreTokenInfo.tokenInfo.szDecimals
            : initialCoreTokenInfo.tokenInfo.szDecimals;
        uint256 spotX1e8 = spotPxRaw * (10 ** additionalPowersOf10);

        // Buy above spot, sell below spot
        uint256 adjPpm = finalTokenInfo.isBuy
            ? (PPM_SCALAR + finalTokenInfo.suggestedDiscountBps * 10 ** 2 + finalTokenInfo.feePpm)
            : (PPM_SCALAR - finalTokenInfo.suggestedDiscountBps * 10 ** 2 - finalTokenInfo.feePpm);
        limitPriceX1e8 = uint64((uint256(spotX1e8) * adjPpm) / PPM_SCALAR);
    }

    /**************************************
     *            SWEEP FUNCTIONS         *
     **************************************/

    function sweepNative(uint256 amount) external onlyRole(FUNDS_SWEEPER_ROLE) {
        (bool success, ) = msg.sender.call{ value: amount }("");
        require(success, "Failed to send native funds");
    }

    function sweepErc20(address token, uint256 amount) external onlyRole(FUNDS_SWEEPER_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function sweepErc20FromDonationBox(address token, uint256 amount) external onlyRole(FUNDS_SWEEPER_ROLE) {
        donationBox.withdraw(IERC20(token), amount);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function sweepERC20FromSwapHandler(address token, uint256 amount) external onlyRole(FUNDS_SWEEPER_ROLE) {
        SwapHandler swapHandler = _getExistingFinalTokenInfo(token).swapHandler;
        swapHandler.sweepErc20(token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function sweepOnCore(address token, uint64 amount) external onlyRole(FUNDS_SWEEPER_ROLE) {
        HyperCoreLib.transferERC20CoreToCore(_getMainStorage().coreTokenInfos[token].coreIndex, msg.sender, amount);
    }

    function sweepOnCoreFromSwapHandler(
        address finalToken,
        uint64 finalTokenAmount,
        uint64 baseTokenAmount
    ) external onlyRole(FUNDS_SWEEPER_ROLE) {
        MainStorage storage $ = _getMainStorage();
        require($.lastPullFundsBlock[finalToken] < block.number, "Can't pull funds twice in the same block");
        $.lastPullFundsBlock[finalToken] = block.number;

        SwapHandler swapHandler = $.finalTokenInfos[finalToken].swapHandler;
        if (finalTokenAmount > 0) {
            swapHandler.transferFundsToUserOnCore($.coreTokenInfos[finalToken].coreIndex, msg.sender, finalTokenAmount);
        }
        if (baseTokenAmount > 0) {
            swapHandler.transferFundsToUserOnCore($.coreTokenInfos[baseToken].coreIndex, msg.sender, baseTokenAmount);
        }
    }
}
