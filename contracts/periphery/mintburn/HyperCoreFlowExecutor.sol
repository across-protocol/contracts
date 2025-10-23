//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { DonationBox } from "../../chain-adapters/DonationBox.sol";
import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { CoreTokenInfo } from "./Structs.sol";
import { FinalTokenInfo } from "./Structs.sol";
import { SwapHandler } from "./SwapHandler.sol";
import { BPS_SCALAR, BPS_DECIMALS } from "./Constants.sol";
import { Lockable } from "../../Lockable.sol";
import { CommonFlowParams } from "./Structs.sol";

/**
 * @title HyperCoreFlowExecutor
 * @notice Contract handling HyperCore interactions for transfer-to-core or swap-with-core actions after stablecoin bridge transactions
 * @dev This contract is designed to work with stablecoins. baseToken and every finalToken should all be stablecoins.
 * @custom:security-contact bugs@across.to
 */
contract HyperCoreFlowExecutor is AccessControl, Lockable {
    using SafeERC20 for IERC20;

    // Common decimals scalars
    uint256 public constant PPM_DECIMALS = 6;
    uint256 public constant PPM_SCALAR = 10 ** PPM_DECIMALS;
    // Decimals to use for Price calculations in limit order-related calculation functions
    uint8 public constant PX_D = 8;
    uint64 public constant ONEX1e8 = 10 ** 8;

    // Roles
    bytes32 public constant PERMISSIONED_BOT_ROLE = keccak256("PERMISSIONED_BOT_ROLE");
    bytes32 public constant FUNDS_SWEEPER_ROLE = keccak256("FUNDS_SWEEPER_ROLE");

    /// @notice The donation box contract.
    DonationBox public immutable donationBox;

    /// @notice A mapping of token addresses to their core token info.
    mapping(address => CoreTokenInfo) public coreTokenInfos;

    /// @notice A mapping of token address to additional relevan info for final tokens, like Hyperliquid market params
    mapping(address => FinalTokenInfo) public finalTokenInfos;

    /// @notice All operations performed in this contract are relative to this baseToken
    address public immutable baseToken;

    /// @notice The block number of the last funds pull action per final token: either as a part of finalizing pending swaps,
    /// or an admin funds pull
    mapping(address finalToken => uint256 lastPullFundsBlock) public lastPullFundsBlock;

    /// @notice A struct used for storing state of a swap flow that has been initialized, but not yet finished
    struct SwapFlowState {
        address finalRecipient;
        address finalToken;
        uint64 minAmountToSend; // for sponsored: one to one, non-sponsored: one to one minus slippage
        uint64 maxAmountToSend; // for sponsored: one to one (from total bridged amt), for non-sponsored: one to one, less bridging fees incurred
        bool isSponsored;
        bool finalized;
    }

    /// @notice A mapping containing the pending state between initializing the swap flow and finalizing it
    mapping(bytes32 quoteNonce => SwapFlowState swap) public swaps;

    /// @notice The cumulative amount of funds sponsored for each final token.
    mapping(address => uint256) public cumulativeSponsoredAmount;
    /// @notice The cumulative amount of activation fees sponsored for each final token.
    mapping(address => uint256) public cumulativeSponsoredActivationFee;

    /**************************************
     *            EVENTS               *
     **************************************/

    /// @notice Emitted when the donation box is insufficient funds.
    event DonationBoxInsufficientFunds(bytes32 indexed quoteNonce, address token, uint256 amount, uint256 balance);

    /// @notice Emitted whenever the account is not activated in the non-sponsored flow. We fall back to HyperEVM flow in that case
    event AccountNotActivated(bytes32 indexed quoteNonce, address user);

    /// @notice Emitted when a simple transfer to core is executed.
    event SimpleTransferFlowCompleted(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // All amounts are in finalToken
        uint256 evmAmountIn,
        uint256 bridgingFeesIncurred,
        uint256 evmAmountSponsored
    );

    /// @notice Emitted upon successful completion of fallback HyperEVM flow
    event FallbackHyperEVMFlowCompleted(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // All amounts are in finalToken
        uint256 evmAmountIn,
        uint256 bridgingFeesIncurred,
        uint256 evmAmountSponsored
    );

    /// @notice Emitted when a swap flow is initialized
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

    /// @notice Emitted when a swap flow is finalized
    event SwapFlowFinalized(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // In finalToken
        uint64 totalSent,
        // In EVM finalToken
        uint256 evmAmountSponsored
    );

    /// @notice Emitted upon cancelling a Limit order
    event CancelledLimitOrder(address indexed token, uint128 indexed cloid);

    /// @notice Emitted upon cancelling a Limit order
    event SubmittedLimitOrder(address indexed token, uint64 priceX1e8, uint64 sizeX1e8, uint128 indexed cloid);

    /// @notice Emitted when we have to fall back from the swap flow because it's too expensive (either to sponsor or the slippage is too big)
    event SwapFlowTooExpensive(
        bytes32 indexed quoteNonce,
        address indexed finalToken,
        uint256 estBpsSlippage,
        uint256 maxAllowableBpsSlippage
    );

    /// @notice Emitted when we can't bridge some token from HyperEVM to HyperCore
    event UnsafeToBridge(bytes32 indexed quoteNonce, address indexed token, uint64 amount);

    /// @notice Emitted whenever donationBox funds are used for activating a user account
    event SponsoredAccountActivation(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed fundingToken,
        uint256 evmAmountSponsored
    );

    /// @notice Emitted whenever a new CoreTokenInfo is configured
    event SetCoreTokenInfo(
        address indexed token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore,
        uint64 bridgeSafetyBufferCore
    );

    /// @notice Emitted when we do an ad-hoc send of sponsorship funds to one of the Swap Handlers
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

    /// @notice Emitted when the donation box is insufficient funds and we can't proceed.
    error DonationBoxInsufficientFundsError(address token, uint256 amount);

    /// @notice Emitted when we're inside the sponsored flow and a user doesn't have a HyperCore account activated. The
    /// bot should activate user's account first by calling `activateUserAccount`
    error AccountNotActivatedError(address user);

    /// @notice Thrown when we can't bridge some token from HyperEVM to HyperCore
    error UnsafeToBridgeError(address token, uint64 amount);

    /**************************************
     *            MODIFIERS               *
     **************************************/

    modifier onlyDefaultAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not default admin");
        _;
    }

    modifier onlyPermissionedBot() {
        require(hasRole(PERMISSIONED_BOT_ROLE, msg.sender), "Not limit order updater");
        _;
    }

    modifier onlyFundsSweeper() {
        require(hasRole(FUNDS_SWEEPER_ROLE, msg.sender), "Not funds sweeper");
        _;
    }

    modifier onlyExistingCoreToken(address evmTokenAddress) {
        _getExistingCoreTokenInfo(evmTokenAddress);
        _;
    }

    /// @notice Reverts if the token is not configured
    function _getExistingCoreTokenInfo(
        address evmTokenAddress
    ) internal view returns (CoreTokenInfo memory coreTokenInfo) {
        coreTokenInfo = coreTokenInfos[evmTokenAddress];
        require(
            coreTokenInfo.tokenInfo.evmContract != address(0) && coreTokenInfo.tokenInfo.weiDecimals != 0,
            "CoreTokenInfo not set"
        );
    }

    /// @notice Reverts if the token is not configured
    function _getExistingFinalTokenInfo(
        address evmTokenAddress
    ) internal view returns (FinalTokenInfo memory finalTokenInfo) {
        finalTokenInfo = finalTokenInfos[evmTokenAddress];
        require(address(finalTokenInfo.swapHandler) != address(0), "FinalTokenInfo not set");
    }

    /**
     *
     * @param _donationBox Sponsorship funds live here
     * @param _baseToken Main token used with this Forwarder
     */
    constructor(address _donationBox, address _baseToken) {
        donationBox = DonationBox(_donationBox);
        baseToken = _baseToken;

        // AccessControl setup
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setRoleAdmin(PERMISSIONED_BOT_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(FUNDS_SWEEPER_ROLE, DEFAULT_ADMIN_ROLE);
    }

    /**************************************
     *      CONFIGURATION FUNCTIONS       *
     **************************************/

    /**
     * @notice Set or update information for the token to use it in this contract
     * @dev To be able to use the token in the swap flow, FinalTokenInfo has to be set as well
     * @dev Setting core token info to incorrect values can lead to loss of funds. Should NEVER be unset while the
     * finalTokenParams are not unset
     */
    function setCoreTokenInfo(
        address token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore,
        uint64 bridgeSafetyBufferCore
    ) external nonReentrant onlyDefaultAdmin {
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
    )
        external
        nonReentrant
        onlyExistingCoreToken(finalToken)
        onlyExistingCoreToken(accountActivationFeeToken)
        onlyDefaultAdmin
    {
        SwapHandler swapHandler = finalTokenInfos[finalToken].swapHandler;
        if (address(swapHandler) == address(0)) {
            bytes32 salt = _swapHandlerSalt(finalToken);
            swapHandler = new SwapHandler{ salt: salt }();
        }

        finalTokenInfos[finalToken] = FinalTokenInfo({
            assetIndex: assetIndex,
            isBuy: isBuy,
            feePpm: feePpm,
            swapHandler: swapHandler,
            suggestedDiscountBps: suggestedDiscountBps
        });

        // We don't allow SwapHandler accounts to be uninitiated. That could lead to loss of funds. They instead should
        // be pre-funded using `predictSwapHandler` to predict their address
        require(HyperCoreLib.coreUserExists(address(swapHandler)), "SwapHandler @ core doesn't exist");
    }

    /// @notice Predicts the deterministic address of a SwapHandler for a given finalToken using CREATE2
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
     * @notice This function is to be called by an inheriting contract. It is to be called after the child contract
     * checked the API signature and made sure that the params passed here have been verified by either the underlying
     * bridge mechanics, or API signaure, or both.
     */
    function _executeFlow(CommonFlowParams memory params, uint256 maxUserSlippageBps) internal {
        if (params.finalToken == baseToken) {
            _executeSimpleTransferFlow(params);
        } else {
            _initiateSwapFlow(params, maxUserSlippageBps);
        }
    }

    /// @notice Execute a simple transfer flow in which we transfer `finalToken` to the user on HyperCore after receiving
    /// an amount of finalToken from the user on HyperEVM
    function _executeSimpleTransferFlow(CommonFlowParams memory params) internal virtual {
        address finalToken = params.finalToken;
        CoreTokenInfo storage coreTokenInfo = coreTokenInfos[finalToken];

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
                if (!_availableInDonationBox(params.quoteNonce, coreTokenInfo.tokenInfo.evmContract, amountToSponsor)) {
                    amountToSponsor = 0;
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
            donationBox.withdraw(IERC20(coreTokenInfo.tokenInfo.evmContract), amountToSponsor);
        }

        cumulativeSponsoredAmount[finalToken] += amountToSponsor;

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
     * finalToken. This is the first leg of the swap flow. Next, the bot should submit a limit order through a `submitLimitOrder`
     * function, and then settle the flow via a `finalizeSwapFlows` function
     * @dev Only works for stable -> stable swap flows (or equivalent token flows. Price between tokens is supposed to be approximately one to one)
     * @param maxUserSlippageBps Describes a configured user setting. Slippage here is wrt the one to one exchange
     */
    function _initiateSwapFlow(CommonFlowParams memory params, uint256 maxUserSlippageBps) internal {
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

        address initialToken = baseToken;
        CoreTokenInfo memory initialCoreTokenInfo = coreTokenInfos[initialToken];
        CoreTokenInfo memory finalCoreTokenInfo = coreTokenInfos[params.finalToken];
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

            uint64 approxExecutionPriceX1e8 = _getApproxRealizedPrice(finalTokenInfo);
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
        swaps[params.quoteNonce] = SwapFlowState({
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

        // Send amount received form user to a corresponding SwapHandler
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
     */
    function finalizeSwapFlows(
        address finalToken,
        bytes32[] calldata quoteNonces,
        uint64[] calldata limitOrderOuts
    ) external onlyPermissionedBot returns (uint256 finalized) {
        require(quoteNonces.length == limitOrderOuts.length, "length");
        require(lastPullFundsBlock[finalToken] < block.number, "too soon");

        CoreTokenInfo memory finalCoreTokenInfo = _getExistingCoreTokenInfo(finalToken);
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[finalToken];

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
                availableBalance
            );
            if (!success) {
                break;
            }
            totalAdditionalToSend += additionalToSend;
        }

        if (finalized > 0) {
            lastPullFundsBlock[finalToken] = block.number;
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
                revert UnsafeToBridgeError(finalCoreTokenInfo.tokenInfo.evmContract, totalAdditionalToSend);
            }

            cumulativeSponsoredAmount[finalToken] += totalAdditionalToSendEVM;

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
        uint64 availableBalance
    ) internal returns (bool success, uint64 additionalToSend, uint64 balanceRemaining) {
        SwapFlowState storage swap = swaps[quoteNonce];
        if (swap.finalRecipient == address(0)) revert SwapDoesNotExist();
        if (swap.finalized) revert SwapAlreadyFinalized();
        if (swap.finalToken != finalCoreTokenInfo.tokenInfo.evmContract) revert WrongSwapFinalizationToken(quoteNonce);

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

        HyperCoreLib.transferERC20CoreToCore(finalCoreTokenInfo.coreIndex, swap.finalRecipient, totalToSend);
        emit SwapFlowFinalized(quoteNonce, swap.finalRecipient, swap.finalToken, totalToSend, additionalToSendEVM);
    }

    /// @notice Forwards `amount` plus potential sponsorship funds (for bridging fee) to user on HyperEVM
    function _fallbackHyperEVMFlow(CommonFlowParams memory params) internal virtual {
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
        cumulativeSponsoredAmount[params.finalToken] += sponsorshipFundsToForward;
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
    ) external nonReentrant onlyPermissionedBot {
        CoreTokenInfo memory coreTokenInfo = _getExistingCoreTokenInfo(fundingToken);
        bool coreUserExists = HyperCoreLib.coreUserExists(finalRecipient);
        require(coreUserExists == false, "Can't fund account activation for existing user");
        require(coreTokenInfo.canBeUsedForAccountActivation, "Token can't be used for this");
        bool safeToBridge = HyperCoreLib.isCoreAmountSafeToBridge(
            coreTokenInfo.coreIndex,
            coreTokenInfo.accountActivationFeeCore,
            coreTokenInfo.bridgeSafetyBufferCore
        );
        require(safeToBridge, "Not safe to bridge");
        uint256 activationFeeEvm = coreTokenInfo.accountActivationFeeEVM;
        cumulativeSponsoredActivationFee[fundingToken] += activationFeeEvm;

        // donationBox @ evm -> Handler @ evm
        donationBox.withdraw(IERC20(fundingToken), activationFeeEvm);
        // Handler @ evm -> Handler @ core -> finalRecipient @ core
        HyperCoreLib.transferERC20EVMToCore(
            fundingToken,
            coreTokenInfo.coreIndex,
            finalRecipient,
            activationFeeEvm,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        emit SponsoredAccountActivation(quoteNonce, finalRecipient, fundingToken, activationFeeEvm);
    }

    /// @notice Cancells a pending limit order by `cloid` with an intention to submit a new limit order in its place. To
    /// be used for stale limit orders to speed up executing user transactions
    function cancelLimitOrderByCloid(address finalToken, uint128 cloid) external nonReentrant onlyPermissionedBot {
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[finalToken];
        finalTokenInfo.swapHandler.cancelOrderByCloid(finalTokenInfo.assetIndex, cloid);

        emit CancelledLimitOrder(finalToken, cloid);
    }

    function submitLimitOrderFromBot(
        address finalToken,
        uint64 priceX1e8,
        uint64 sizeX1e8,
        uint128 cloid
    ) external nonReentrant onlyPermissionedBot {
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[finalToken];
        finalTokenInfo.swapHandler.submitLimitOrder(finalTokenInfo, priceX1e8, sizeX1e8, cloid);

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
        require(tokenInfo.evmContract == token, "Token mismatch");

        (uint256 accountActivationFeeEVM, ) = HyperCoreLib.minimumCoreReceiveAmountToAmounts(
            accountActivationFeeCore,
            tokenInfo.evmExtraWeiDecimals
        );

        coreTokenInfos[token] = CoreTokenInfo({
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
     */
    function sendSponsorshipFundsToSwapHandler(address token, uint256 amount) external onlyPermissionedBot {
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

        cumulativeSponsoredAmount[token] += amountEVMToSend;

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
            // Maximum allowable amount to forward is a one-to-one equivalent of `amount`
            maxAllowableAmountToForwardCore = uint64(
                (feelessAmountCoreFinalToken * amount) / (amount + extraFeesIncurred)
            );
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
        // What we will send from donationBox right now
        // What we will forward to user on HCore
        if (limitOrderOut >= maxAmountToSend || isSponsored) {
            totalToSend = maxAmountToSend;
        } else {
            if (limitOrderOut < minAmountToSend) {
                additionalToSend = minAmountToSend - limitOrderOut;
            }

            // Give user a fair deal, which is the max of:
            // - limitOrderOut
            // - minAmountToSend
            totalToSend = limitOrderOut + additionalToSend;
        }
    }

    /// @notice Reads the current spot price from HyperLiquid and applies a configured suggested discount for faster execution
    /// @dev Includes HyperLiquid fees
    function _getApproxRealizedPrice(
        FinalTokenInfo memory finalTokenInfo
    ) internal view returns (uint64 limitPriceX1e8) {
        uint64 spotX1e8 = HyperCoreLib.spotPx(finalTokenInfo.assetIndex);
        // Buy above spot, sell below spot
        uint256 adjPpm = finalTokenInfo.isBuy
            ? (PPM_SCALAR + finalTokenInfo.suggestedDiscountBps * 10 ** 2 + finalTokenInfo.feePpm)
            : (PPM_SCALAR - finalTokenInfo.suggestedDiscountBps * 10 ** 2 - finalTokenInfo.feePpm);
        limitPriceX1e8 = uint64((uint256(spotX1e8) * adjPpm) / PPM_SCALAR);
    }

    /**************************************
     *            SWEEP FUNCTIONS         *
     **************************************/

    function sweepErc20(address token, uint256 amount) external nonReentrant onlyFundsSweeper {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function sweepErc20FromDonationBox(address token, uint256 amount) external nonReentrant onlyFundsSweeper {
        donationBox.withdraw(IERC20(token), amount);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function sweepERC20FromSwapHandler(address token, uint256 amount) external nonReentrant onlyFundsSweeper {
        SwapHandler swapHandler = finalTokenInfos[token].swapHandler;
        swapHandler.sweepErc20(token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function sweepOnCore(address token, uint64 amount) external nonReentrant onlyFundsSweeper {
        HyperCoreLib.transferERC20CoreToCore(coreTokenInfos[token].coreIndex, msg.sender, amount);
    }

    function sweepOnCoreFromSwapHandler(address token, uint64 amount) external nonReentrant onlyDefaultAdmin {
        // Prevent pulling fantom funds (e.g. if finalizePendingSwaps reads stale balance because of this fund pull)
        require(lastPullFundsBlock[token] < block.number, "Can't pull funds twice in the same block");
        lastPullFundsBlock[token] = block.number;

        SwapHandler swapHandler = finalTokenInfos[token].swapHandler;
        swapHandler.transferFundsToUserOnCore(finalTokenInfos[token].assetIndex, msg.sender, amount);
    }
}
