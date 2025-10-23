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
import { BPS_SCALAR } from "./Constants.sol";
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
        // in tokenIn
        uint64 budget; // TODO: mb not required
        address tokenIn;
        address finalToken;
        uint64 maxToSponsorFinalToken; // TODO: maybe just for data purposes
        uint64 targetAmountFinalToken; // target amount to send to finalRecipient
        // if isSposored, send up to `targetAmountFinalToken`
        // if not sponsored, send `loOut`
        bool isSponsored;
        address finalRecipient;
        bool finalized;
    }

    /// @notice A mapping containing the pending state between initializing the swap flow and finalizing it
    mapping(bytes32 quoteNonce => SwapFlowState swap) public swaps;

    /// @notice The cumulative amount of funds sponsored for each final token.
    mapping(address => uint256) public cumulativeSponsoredAmount;
    /// @notice The cumulative amount of activation fees sponsored for each final token.
    mapping(address => uint256) public cumulativeSponsoredActivationFee;

    /// @notice Emitted when the donation box is insufficient funds.
    event DonationBoxInsufficientFunds(address token, uint256 amount);

    /// @notice Emitted when the donation box is insufficient funds and we can't proceed.
    error DonationBoxInsufficientFundsError(address token, uint256 amount);

    /// @notice Emitted when we're inside the sponsored flow and a user doesn't have a HyperCore account activated. The
    /// bot should activate user's account first by calling `activateUserAccount`
    error AccountNotActivated(address user);

    /// @notice Emitted when a simple transfer to core is executed.
    event SimpleTransferFlowCompleted(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // All amounts are in finalToken
        uint256 evmAmountReceived,
        uint256 evmAmountSponsored,
        uint256 evmAmountTransferred,
        uint64 coreAmountTransferred
    );

    /// @notice Emitted upon successful completion of fallback HyperEVM flow
    event FallbackHyperEVMFlowCompleted(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // All amounts are in finalToken
        uint256 evmAmountReceived,
        uint256 evmAmountSponsored,
        uint256 evmAmountTransferred
    );

    /// @notice Emitted when a swap flow is initialized
    event SwapFlowInitialized(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // In baseToken
        uint256 evmAmountReceived,
        // Two below in finalToken
        uint256 evmAmountSponsored,
        uint64 targetCoreAmountToTransfer,
        uint32 asset,
        uint128 cloid
    );

    /// @notice Emitted upon successful completion of swap flow
    event SwapFlowCompleted(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed finalToken,
        // Two below in finalToken
        uint256 coreAmountSponsored,
        uint64 coreAmountTransferred
    );

    /// @notice Emitted upon cancelling a Limit order associated with an active swap flow
    event CancelledLimitOrder(bytes32 indexed quoteNonce, uint32 indexed asset, uint128 indexed cloid);

    /// @notice Emitted upon submitting a new Limit order in place of a cancelled one
    event ReplacedOldLimitOrder(
        bytes32 indexed quoteNonce,
        uint128 indexed cloid,
        uint64 priceX1e8,
        uint64 sizeX1e8,
        uint64 oldPriceX1e8,
        uint64 oldSizeX1e8Left
    );

    /// @notice Emitted when the replacing Limit order has better price than the old one
    event BetterPricedLOSubmitted(bytes32 indexed quoteNonce, uint64 oldPriceX1e8, uint64 priceX1e8);

    /// @notice Emitted from the simple trasnfer flow when we fall back to HyperEVM flow because a non-sponsored transfer's recipient has no HyperCore account
    event SimpleTransferFallbackAccountActivation(bytes32 indexed quoteNonce);

    /// @notice Emitted from the simple trasnfer flow when we fall back to HyperEVM flow because bridging would be unsafe
    event SimpleTransferFallbackUnsafeToBridge(bytes32 indexed quoteNonce);

    /// @notice Emitted from the swap flow when we fall back to HyperEVM flow because a non-sponsored transfer's recipient has no HyperCore account
    event SwapFlowFallbackAccountActivation(bytes32 indexed quoteNonce);

    /// @notice Emitted from the swap flow when falling back to the other flow becase the cost is to high compared to sponsored settings
    event SwapFlowFallbackTooExpensive(
        bytes32 indexed quoteNonce,
        // Based on minimum out requirements for sponsored / non-sponsored flows
        uint64 requiredCoreAmountToSponsor,
        // Based on maxBpsToSponsor
        uint64 maxCoreAmountToSponsor
    );

    /// @notice Emitted from the swap flow when falling back to the other flow becase donation box doesn't have enough funds to sponsor the flow
    event SwapFlowFallbackDonationBox(
        bytes32 indexed quoteNonce,
        address indexed finalToken,
        uint256 totalEVMAmountToSponsor
    );

    /// @notice Emitted from the swap flow when falling back to the other flow becase bridging to core was unsafe (spot bridge didn't have enough funds)
    event SwapFlowFallbackUnsafeToBridge(
        bytes32 indexed quoteNonce,
        bool initTokenUnsafe,
        address indexed finalToken,
        bool finalTokenUnsafe
    );

    /// @notice Emitted whenever donationBox funds are used for activating a user account
    event SponsoredAccountActivation(
        bytes32 indexed quoteNonce,
        address indexed finalRecipient,
        address indexed fundingToken,
        uint256 evmAmount
    );

    /// @notice Emitted whenever a new CoreTokenInfo is configured
    event SetCoreTokenInfo(
        address indexed token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore,
        uint64 bridgeSafetyBufferCore
    );

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
                revert AccountNotActivated(params.finalRecipient);
            } else {
                _fallbackHyperEVMFlow(params);
                emit SimpleTransferFallbackAccountActivation(params.quoteNonce);
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
                if (!_availableInDonationBox(coreTokenInfo.tokenInfo.evmContract, amountToSponsor)) {
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
                emit SimpleTransferFallbackUnsafeToBridge(params.quoteNonce);
                return;
            }
        }

        if (amountToSponsor > 0) {
            // This will succeed because we checked the balance earlier
            _getFromDonationBox(coreTokenInfo.tokenInfo.evmContract, amountToSponsor);
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
            amountToSponsor,
            quotedEvmAmount,
            quotedCoreAmount
        );
    }

    /// @notice initialized swap flow to eventually forward `finalToken` to the user, starting from `baseToken` (received
    /// from a user bridge transaction)
    function _initiateSwapFlow(
        CommonFlowParams memory params,
        // `maxUserSlippageBps` here means how much token user receives compared to a 1 to 1
        uint256 maxUserSlippageBps
    ) internal {
        // Check account activation
        if (!HyperCoreLib.coreUserExists(params.finalRecipient)) {
            if (params.maxBpsToSponsor > 0) {
                revert AccountNotActivated(params.finalRecipient);
            } else {
                _fallbackHyperEVMFlow(params);
                emit SwapFlowFallbackAccountActivation(params.quoteNonce);
                return;
            }
        }

        FinalTokenInfo memory finalTokenInfo = _getExistingFinalTokenInfo(params.finalToken);
        address initialToken = baseToken;
        CoreTokenInfo memory initialCoreTokenInfo = coreTokenInfos[initialToken];
        CoreTokenInfo memory finalCoreTokenInfo = coreTokenInfos[params.finalToken];
        uint64 tokensToSendCore;

        // Calculate limit order amounts and check if feasible
        uint64 minAllowableAmountToForwardCore;
        {
            // In initialToken
            (, uint64 amountInEquivalentCore) = HyperCoreLib.maximumEVMSendAmountToAmounts(
                params.amountInEVM,
                initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
            );

            // In finalToken
            uint64 maxAmountToSponsorCore;
            (minAllowableAmountToForwardCore, maxAmountToSponsorCore) = _calculateAllowableAmountsForFlow(
                params.amountInEVM + params.extraFeesIncurred,
                initialCoreTokenInfo,
                finalCoreTokenInfo,
                params.maxBpsToSponsor > 0,
                params.maxBpsToSponsor,
                maxUserSlippageBps
            );

            uint64 ONEX1e8 = 10 ** 8;
            uint64 approxExecutionPriceX1e8 = _getSuggestedApproxPrice(finalTokenInfo);
            uint256 maxAllowableBpsDeviation = params.maxBpsToSponsor > 0 ? params.maxBpsToSponsor : maxUserSlippageBps;
            uint256 harmfulDeviationBps; // deviation that is "against our trade direction"
            if (finalTokenInfo.isBuy) {
                if (approxExecutionPriceX1e8 < ONEX1e8) {
                    harmfulDeviationBps = 0;
                } else {
                    // ceil
                    harmfulDeviationBps = (approxExecutionPriceX1e8 - ONEX1e8) * BPS_SCALAR + (ONEX1e8 - 1) / ONEX1e8;
                }
            } else {
                if (approxExecutionPriceX1e8 > ONEX1e8) {
                    harmfulDeviationBps = 0;
                } else {
                    // ceil
                    harmfulDeviationBps = (ONEX1e8 - approxExecutionPriceX1e8) * BPS_SCALAR + (ONEX1e8 - 1) / ONEX1e8;
                }
            }

            if (harmfulDeviationBps > maxAllowableBpsDeviation) {
                params.finalToken = initialToken;
                _executeSimpleTransferFlow(params);
                // TODO: emit fallback event
                return;
            }
        }

        // Check that we can safely bridge to HCore (for the trade amount actually needed)
        bool isSafeToBridgeMainToken = HyperCoreLib.isCoreAmountSafeToBridge(
            initialCoreTokenInfo.coreIndex,
            tokensToSendCore,
            initialCoreTokenInfo.bridgeSafetyBufferCore
        );

        if (!isSafeToBridgeMainToken) {
            params.finalToken = initialToken;
            _fallbackHyperEVMFlow(params);
            // emit SwapFlowFallbackUnsafeToBridge(
            //     params.quoteNonce,
            //     isSafeToBridgeMainToken,
            //     params.finalToken,
            //     true
            // );
            return;
        }

        // Finalize swap flow setup by updating state and funding SwapHandler
        // State changes
        swaps[params.quoteNonce] = SwapFlowState({
            budget: tokensToSendCore,
            tokenIn: initialToken,
            finalToken: params.finalToken,
            maxToSponsorFinalToken: uint64(0), // TODO,
            targetAmountFinalToken: minAllowableAmountToForwardCore,
            isSponsored: params.maxBpsToSponsor > 0,
            finalRecipient: params.finalRecipient,
            finalized: false
        });

        // TODO
        // emit SwapFlowInitialized(
        //     params.quoteNonce,
        //     params.finalRecipient,
        //     params.finalToken,
        //     params.amountInEVM,
        //     totalEVMAmountToSponsor,
        //     finalCoreSendAmount,
        //     finalTokenInfo.assetIndex,
        //     cloid
        // );

        // Send amount received form user to a corresponding SwapHandler
        SwapHandler swapHandler = finalTokenInfo.swapHandler;
        (uint256 evmToSendForTrade, ) = HyperCoreLib.minimumCoreReceiveAmountToAmounts(
            tokensToSendCore,
            initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
        IERC20(initialToken).safeTransfer(address(swapHandler), evmToSendForTrade);
        swapHandler.transferFundsToSelfOnCore(
            initialToken,
            initialCoreTokenInfo.coreIndex,
            evmToSendForTrade,
            initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
    }

    function finalizeSwap(bytes32 quoteNonce, uint64 limitOrderOut) external onlyPermissionedBot {
        SwapFlowState memory swap = swaps[quoteNonce];
        require(swap.finalRecipient != address(0), "swap does not exist");
        require(swap.finalized == false, "already finalized");
        swap.finalized = true;

        CoreTokenInfo memory finalCoreTokenInfo = coreTokenInfos[swap.finalToken];
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[swap.finalToken];

        // What we will send from donationBox right now
        uint64 additionalToSend;
        if (limitOrderOut < swap.targetAmountFinalToken) {
            if (swap.isSponsored) {
                // This is our sponsor amount
                additionalToSend = swap.targetAmountFinalToken - limitOrderOut;
            } else {
                additionalToSend = swap.targetAmountFinalToken - limitOrderOut;
            }
        }

        // What we will forward to user on HCore
        uint64 totalToSend;
        if (swap.isSponsored) {
            totalToSend = swap.targetAmountFinalToken;
        } else {
            // Give user a fair deal instead of sending the minimum allowable amount (which means max slippage)
            totalToSend = limitOrderOut + additionalToSend;
        }

        // TODO: what to do if we can't bridge? Just forward on HyperEVM? Seems bad, but *workable*

        (uint256 additionalToSendEVM, ) = HyperCoreLib.minimumCoreReceiveAmountToAmounts(
            additionalToSend,
            finalCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        // TODO: is bridge safe?
        // Get additional amount to send from donation box, and send it to self on core
        if (additionalToSendEVM > 0) {
            _getFromDonationBox(swap.finalToken, additionalToSendEVM);
            IERC20(swap.finalToken).safeTransfer(address(finalTokenInfo.swapHandler), additionalToSendEVM);
            finalTokenInfo.swapHandler.transferFundsToSelfOnCore(
                swap.finalToken,
                finalCoreTokenInfo.coreIndex,
                additionalToSendEVM,
                finalCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
            );
        }

        // Send to user
        HyperCoreLib.transferERC20CoreToCore(
            finalCoreTokenInfo.coreIndex,
            swap.finalRecipient,
            limitOrderOut + additionalToSend
        );
        // TODO: emit event
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
        _getFromDonationBox(fundingToken, activationFeeEvm);
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
    function cancelLimitOrderByCloid(
        address finalToken,
        uint128 cloid
    ) external nonReentrant onlyPermissionedBot returns (bytes32 quoteNonce) {
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[finalToken];
        finalTokenInfo.swapHandler.cancelOrderByCloid(finalTokenInfo.assetIndex, cloid);

        // TODO: consider emitting event
        // emit CancelledLimitOrder(quoteNonce, finalTokenInfo.assetIndex, cloid);
    }

    function submitLimitOrderFromBot(
        address finalToken,
        uint64 priceX1e8,
        uint64 sizeX1e8,
        uint128 cloid
    ) external nonReentrant onlyPermissionedBot {
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[finalToken];
        finalTokenInfo.swapHandler.submitLimitOrder(finalTokenInfo, priceX1e8, sizeX1e8, cloid);

        // TODO: submittedLimitOrder
        // emit ReplacedOldLimitOrder(quoteNonce, cloid, priceX1e8, szX1e8, oldPriceX1e8, oldSizeX1e8Left);
    }

    /// @notice Forwards `amount` plus potential sponsorship funds (for bridging fee) to user on HyperEVM
    function _fallbackHyperEVMFlow(CommonFlowParams memory params) internal virtual {
        uint256 maxEvmAmountToSponsor = ((params.amountInEVM + params.extraFeesIncurred) * params.maxBpsToSponsor) /
            BPS_SCALAR;
        uint256 sponsorshipFundsToForward = params.extraFeesIncurred > maxEvmAmountToSponsor
            ? maxEvmAmountToSponsor
            : params.extraFeesIncurred;

        if (!_availableInDonationBox(params.finalToken, sponsorshipFundsToForward)) {
            sponsorshipFundsToForward = 0;
        }
        if (sponsorshipFundsToForward > 0) {
            _getFromDonationBox(params.finalToken, sponsorshipFundsToForward);
        }
        uint256 totalAmountToForward = params.amountInEVM + sponsorshipFundsToForward;
        IERC20(params.finalToken).safeTransfer(params.finalRecipient, totalAmountToForward);
        cumulativeSponsoredAmount[params.finalToken] += sponsorshipFundsToForward;
        emit FallbackHyperEVMFlowCompleted(
            params.quoteNonce,
            params.finalRecipient,
            params.finalToken,
            params.amountInEVM,
            sponsorshipFundsToForward,
            totalAmountToForward
        );
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

    /// @notice Gets `amount` of `token` from donationBox. Reverts if unsuccessful
    function _getFromDonationBox(address token, uint256 amount) internal {
        if (!_availableInDonationBox(token, amount)) {
            revert DonationBoxInsufficientFundsError(token, amount);
        }
        donationBox.withdraw(IERC20(token), amount);
    }

    /// @notice Checks if `amount` of `token` is available to withdraw from donationBox
    function _availableInDonationBox(address token, uint256 amount) internal returns (bool available) {
        available = IERC20(token).balanceOf(address(donationBox)) >= amount;
        if (!available) {
            emit DonationBoxInsufficientFunds(token, amount);
        }
    }

    function _calculateAllowableAmountsForFlow(
        uint256 totalAmountBridgedEVM,
        CoreTokenInfo memory initialCoreTokenInfo,
        CoreTokenInfo memory finalCoreTokenInfo,
        bool isSponsoredFlow,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps
    ) internal pure returns (uint64 minAllowableAmountToForwardCore, uint64 maxAmountToSponsorCore) {
        (, uint64 feelessAmountCoreInitialToken) = HyperCoreLib.maximumEVMSendAmountToAmounts(
            totalAmountBridgedEVM,
            initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
        uint64 feelessAmountCoreFinalToken = HyperCoreLib.convertCoreDecimalsSimple(
            feelessAmountCoreInitialToken,
            initialCoreTokenInfo.tokenInfo.weiDecimals,
            finalCoreTokenInfo.tokenInfo.weiDecimals
        );
        if (isSponsoredFlow) {
            maxAmountToSponsorCore = uint64((feelessAmountCoreFinalToken * maxBpsToSponsor) / BPS_SCALAR);
            minAllowableAmountToForwardCore = feelessAmountCoreFinalToken;
        } else {
            maxAmountToSponsorCore = 0;
            minAllowableAmountToForwardCore = uint64(
                (feelessAmountCoreFinalToken * (BPS_SCALAR - maxUserSlippageBps)) / BPS_SCALAR
            );
        }
    }

    /**************************************
     *            SWEEP FUNCTIONS         *
     **************************************/

    function sweepErc20(address token, uint256 amount) external nonReentrant onlyFundsSweeper {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function sweepErc20FromDonationBox(address token, uint256 amount) external nonReentrant onlyFundsSweeper {
        _getFromDonationBox(token, amount);
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

    /// @notice Reads the current spot price from HyperLiquid and applies a configured suggested discount for faster execution
    /// @dev INCLUDES HYPERLIQUID FEES
    function _getSuggestedApproxPrice(
        FinalTokenInfo memory finalTokenInfo
    ) internal view returns (uint64 limitPriceX1e8) {
        uint64 spotX1e8 = HyperCoreLib.spotPx(finalTokenInfo.assetIndex);
        // Buy above spot, sell below spot
        uint256 adjPpm = finalTokenInfo.isBuy
            ? (PPM_SCALAR + finalTokenInfo.suggestedDiscountBps * 10 ** 2 + finalTokenInfo.feePpm)
            : (PPM_SCALAR - finalTokenInfo.suggestedDiscountBps * 10 ** 2 - finalTokenInfo.feePpm);
        limitPriceX1e8 = uint64((uint256(spotX1e8) * adjPpm) / PPM_SCALAR);
    }
}
