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
    struct PendingSwap {
        address finalRecipient;
        address finalToken;
        /// @notice totalCoreAmountToForwardToUser = minCoreAmountFromLO + sponsoredCoreAmountPreFunded always.
        uint64 minCoreAmountFromLO;
        uint64 sponsoredCoreAmountPreFunded;
        uint128 limitOrderCloid;
    }

    /// @notice Parameters for initiating a swap flow
    struct SwapFlowParams {
        uint256 amountInEVM;
        bytes32 quoteNonce;
        address finalRecipient;
        address finalToken;
        uint256 maxBpsToSponsor;
        uint256 maxUserSlippageBps;
        uint256 extraBridgingFeesEVM;
    }

    /// @notice A mapping containing the pending state between initializing the swap flow and finalizing it
    mapping(bytes32 quoteNonce => PendingSwap pendingSwap) public pendingSwaps;
    /// @notice A FCFS queue of pending swap flows to be executed. Per finalToken
    mapping(address finalToken => bytes32[] quoteNonces) public pendingQueue;
    /// @notice An index of the first unexecuted pending swap flow. Or equal to pendingQueue length if currently empty
    mapping(address => uint256) public pendingQueueHead;

    /// @notice The cumulative amount of funds sponsored for each final token.
    mapping(address => uint256) public cumulativeSponsoredAmount;
    /// @notice The cumulative amount of activation fees sponsored for each final token.
    mapping(address => uint256) public cumulativeSponsoredActivationFee;

    /// @notice Used for uniquely identifying Limit Orders this contract submits. Monotonically increasing
    uint128 public nextCloid;

    /// @notice A mapping from limit order cliod to the quoteNonce (user order id) responsible for submitting the LO
    mapping(uint128 => bytes32) public cloidToQuoteNonce;

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
        // Initialize this to 1 as to save 0 for special events when "no cloid is set" = no associated limit order
        nextCloid = 1;

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
     * @param amountInEVM The real token amount to be used in this flow execution
     * @param extraFeesToSponsor Any fees subtracted from the user up until this point (e.g. CCTP bridging fees)
     */
    function _executeFlow(
        uint256 amountInEVM,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        uint256 maxUserSlippageBps,
        address finalRecipient,
        address finalToken,
        uint256 extraFeesToSponsor
    ) internal {
        if (finalToken == baseToken) {
            _executeSimpleTransferFlow(
                amountInEVM,
                quoteNonce,
                maxBpsToSponsor,
                finalRecipient,
                extraFeesToSponsor,
                finalToken
            );
        } else {
            _initiateSwapFlow(
                SwapFlowParams({
                    amountInEVM: amountInEVM,
                    quoteNonce: quoteNonce,
                    finalRecipient: finalRecipient,
                    finalToken: finalToken,
                    maxBpsToSponsor: maxBpsToSponsor,
                    maxUserSlippageBps: maxUserSlippageBps,
                    extraBridgingFeesEVM: extraFeesToSponsor
                })
            );
        }
    }

    /// @notice Execute a simple transfer flow in which we transfer `finalToken` to the user on HyperCore after receiving
    /// an amount of finalToken from the user on HyperEVM
    function _executeSimpleTransferFlow(
        uint256 amountInEVM,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address finalRecipient,
        uint256 extraBridgingFeesEVM,
        address finalToken
    ) internal virtual {
        CoreTokenInfo storage coreTokenInfo = coreTokenInfos[finalToken];

        // Check account activation
        if (!HyperCoreLib.coreUserExists(finalRecipient)) {
            if (maxBpsToSponsor > 0) {
                revert AccountNotActivated(finalRecipient);
            } else {
                _fallbackHyperEVMFlow(
                    amountInEVM,
                    quoteNonce,
                    maxBpsToSponsor,
                    finalRecipient,
                    extraBridgingFeesEVM,
                    finalToken
                );
                emit SimpleTransferFallbackAccountActivation(quoteNonce);
                return;
            }
        }

        // Calculate sponsorship amount in scope
        uint256 amountToSponsor;
        {
            uint256 maxEvmAmountToSponsor = ((amountInEVM + extraBridgingFeesEVM) * maxBpsToSponsor) / BPS_SCALAR;
            amountToSponsor = extraBridgingFeesEVM;
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
            uint256 finalAmount = amountInEVM + amountToSponsor;
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
                _fallbackHyperEVMFlow(
                    amountInEVM,
                    quoteNonce,
                    maxBpsToSponsor,
                    finalRecipient,
                    extraBridgingFeesEVM,
                    finalToken
                );
                emit SimpleTransferFallbackUnsafeToBridge(quoteNonce);
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
            finalRecipient,
            quotedEvmAmount,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        emit SimpleTransferFlowCompleted(
            quoteNonce,
            finalRecipient,
            finalToken,
            amountInEVM,
            amountToSponsor,
            quotedEvmAmount,
            quotedCoreAmount
        );
    }

    /// @notice initialized swap flow to eventually forward `finalToken` to the user, starting from `baseToken` (received
    /// from a user bridge transaction)
    function _initiateSwapFlow(SwapFlowParams memory params) internal {
        // Check account activation - inline booleans to reduce stack
        if (!HyperCoreLib.coreUserExists(params.finalRecipient)) {
            if (params.maxBpsToSponsor > 0) {
                revert AccountNotActivated(params.finalRecipient);
            } else {
                _fallbackHyperEVMFlow(
                    params.amountInEVM,
                    params.quoteNonce,
                    params.maxBpsToSponsor,
                    params.finalRecipient,
                    params.extraBridgingFeesEVM,
                    baseToken
                );
                emit SwapFlowFallbackAccountActivation(params.quoteNonce);
                return;
            }
        }

        FinalTokenInfo memory finalTokenInfo = _getExistingFinalTokenInfo(params.finalToken);
        address initialToken = baseToken;
        CoreTokenInfo memory initialCoreTokenInfo = coreTokenInfos[initialToken];
        CoreTokenInfo memory finalCoreTokenInfo = coreTokenInfos[params.finalToken];
        uint64 tokensToSendCore;
        uint64 guaranteedLOOut;
        uint64 sizeX1e8;
        uint64 finalCoreSendAmount;
        uint64 totalCoreAmountToSponsor;
        uint256 totalEVMAmountToSponsor;
        {
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
                    params.amountInEVM + params.extraBridgingFeesEVM,
                    initialCoreTokenInfo,
                    finalCoreTokenInfo,
                    params.maxBpsToSponsor > 0,
                    params.maxBpsToSponsor,
                    params.maxUserSlippageBps
                );

                uint64 limitPriceX1e8 = _getSuggestedPriceX1e8(finalTokenInfo);
                (sizeX1e8, tokensToSendCore, guaranteedLOOut) = _calcLOAmounts(
                    amountInEquivalentCore,
                    limitPriceX1e8,
                    finalTokenInfo.isBuy,
                    finalTokenInfo.feePpm,
                    initialCoreTokenInfo,
                    finalCoreTokenInfo
                );

                if (
                    minAllowableAmountToForwardCore > guaranteedLOOut &&
                    minAllowableAmountToForwardCore - guaranteedLOOut > maxAmountToSponsorCore
                ) {
                    // We can't provide the required slippage in a swap flow, try simple transfer flow instead
                    _executeSimpleTransferFlow(
                        params.amountInEVM,
                        params.quoteNonce,
                        params.maxBpsToSponsor,
                        params.finalRecipient,
                        params.extraBridgingFeesEVM,
                        initialToken
                    );
                    emit SwapFlowFallbackTooExpensive(
                        params.quoteNonce,
                        minAllowableAmountToForwardCore - guaranteedLOOut,
                        maxAmountToSponsorCore
                    );
                    return;
                }
            }

            // Calculate sponsorship amounts
            finalCoreSendAmount = params.maxBpsToSponsor > 0 ? minAllowableAmountToForwardCore : guaranteedLOOut;
            totalCoreAmountToSponsor = finalCoreSendAmount > guaranteedLOOut
                ? finalCoreSendAmount - guaranteedLOOut
                : 0;

            totalEVMAmountToSponsor = 0;
            if (totalCoreAmountToSponsor > 0) {
                (totalEVMAmountToSponsor, ) = HyperCoreLib.minimumCoreReceiveAmountToAmounts(
                    totalCoreAmountToSponsor,
                    finalCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
                );
            }

            if (totalEVMAmountToSponsor > 0) {
                if (!_availableInDonationBox(params.finalToken, totalEVMAmountToSponsor)) {
                    // We can't provide the required `totalEVMAmountToSponsor` in a swap flow, try simple transfer flow instead
                    _executeSimpleTransferFlow(
                        params.amountInEVM,
                        params.quoteNonce,
                        params.maxBpsToSponsor,
                        params.finalRecipient,
                        params.extraBridgingFeesEVM,
                        initialToken
                    );
                    emit SwapFlowFallbackDonationBox(params.quoteNonce, params.finalToken, totalEVMAmountToSponsor);
                    return;
                }
            }

            // Check that we can safely bridge to HCore (for the trade amount actually needed)
            bool isSafeToBridgeMainToken = HyperCoreLib.isCoreAmountSafeToBridge(
                initialCoreTokenInfo.coreIndex,
                tokensToSendCore,
                initialCoreTokenInfo.bridgeSafetyBufferCore
            );
            bool isSafeTobridgeSponsorshipFunds = HyperCoreLib.isCoreAmountSafeToBridge(
                finalCoreTokenInfo.coreIndex,
                totalCoreAmountToSponsor,
                finalCoreTokenInfo.bridgeSafetyBufferCore
            );

            if (!isSafeToBridgeMainToken || !isSafeTobridgeSponsorshipFunds) {
                _fallbackHyperEVMFlow(
                    params.amountInEVM,
                    params.quoteNonce,
                    params.maxBpsToSponsor,
                    params.finalRecipient,
                    params.extraBridgingFeesEVM,
                    initialToken
                );
                emit SwapFlowFallbackUnsafeToBridge(
                    params.quoteNonce,
                    isSafeToBridgeMainToken,
                    params.finalToken,
                    isSafeTobridgeSponsorshipFunds
                );
                return;
            }
        }

        // Finalize swap flow setup by updating state and funding SwapHandler
        // State changes
        uint128 cloid = ++nextCloid;
        pendingSwaps[params.quoteNonce] = PendingSwap({
            finalRecipient: params.finalRecipient,
            finalToken: params.finalToken,
            minCoreAmountFromLO: guaranteedLOOut,
            sponsoredCoreAmountPreFunded: totalCoreAmountToSponsor,
            limitOrderCloid: cloid
        });
        pendingQueue[params.finalToken].push(params.quoteNonce);
        cloidToQuoteNonce[cloid] = params.quoteNonce;
        cumulativeSponsoredAmount[params.finalToken] += totalEVMAmountToSponsor;

        emit SwapFlowInitialized(
            params.quoteNonce,
            params.finalRecipient,
            params.finalToken,
            params.amountInEVM,
            totalEVMAmountToSponsor,
            finalCoreSendAmount,
            finalTokenInfo.assetIndex,
            cloid
        );

        SwapHandler swapHandler = finalTokenInfo.swapHandler;
        // Interactions with external contracts
        // 1. Fund SwapHandler @ core with `initialToken`: use it for the trade
        // Always: evmToSendForTrade <= amountInEVM because of how it's calculated
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

        // 2. Fund SwapHandler @ core with `finalToken`: use that for sponsorship
        if (totalEVMAmountToSponsor > 0) {
            // We checked that this amount is in donationBox before
            _getFromDonationBox(params.finalToken, totalEVMAmountToSponsor);
            // These funds just came from donationBox
            IERC20(params.finalToken).safeTransfer(address(swapHandler), totalEVMAmountToSponsor);
            swapHandler.transferFundsToSelfOnCore(
                params.finalToken,
                finalCoreTokenInfo.coreIndex,
                totalEVMAmountToSponsor,
                finalCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
            );
        }

        swapHandler.submitLimitOrder(finalTokenInfo, _getSuggestedPriceX1e8(finalTokenInfo), sizeX1e8, cloid);
    }

    /// @notice Finalizes pending queue of swaps for `finalToken` if a corresponding SwapHandler has enough balance
    function finalizePendingSwaps(
        address finalToken,
        uint256 maxSwapCountToFinalize
    )
        external
        nonReentrant
        returns (uint256 finalizedSwapsCount, uint256 finalizedSwapsAmount, uint256 totalPendingSwapsRemaining)
    {
        FinalTokenInfo memory finalTokenInfo = _getExistingFinalTokenInfo(finalToken);
        CoreTokenInfo memory coreTokenInfo = coreTokenInfos[finalToken];

        require(lastPullFundsBlock[finalToken] < block.number, "Can't finalize twice in the same block");

        uint256 head = pendingQueueHead[finalToken];
        bytes32[] storage queue = pendingQueue[finalToken];
        if (head >= queue.length) return (0, 0, 0);
        if (maxSwapCountToFinalize == 0) return (0, 0, queue.length - head);

        // Note: `availableCore` is the SwapHandler's Core balance for `finalToken`, which monotonically increases
        uint64 availableCore = HyperCoreLib.spotBalance(address(finalTokenInfo.swapHandler), coreTokenInfo.coreIndex);

        while (head < queue.length && finalizedSwapsCount < maxSwapCountToFinalize) {
            bytes32 nonce = queue[head];

            PendingSwap storage pendingSwap = pendingSwaps[nonce];
            uint64 totalAmountToForwardToUser = pendingSwap.minCoreAmountFromLO +
                pendingSwap.sponsoredCoreAmountPreFunded;
            if (availableCore < totalAmountToForwardToUser) {
                break;
            }

            finalTokenInfo.swapHandler.transferFundsToUserOnCore(
                finalTokenInfo.assetIndex,
                pendingSwap.finalRecipient,
                totalAmountToForwardToUser
            );

            emit SwapFlowCompleted(
                nonce,
                pendingSwap.finalRecipient,
                pendingSwap.finalToken,
                pendingSwap.sponsoredCoreAmountPreFunded,
                totalAmountToForwardToUser
            );

            availableCore -= totalAmountToForwardToUser;

            // We don't delete `pendingSwaps` state, because we might require it for accounting purposes if we need to
            // update the associated limit order
            head += 1;
            finalizedSwapsCount += 1;
            finalizedSwapsAmount += totalAmountToForwardToUser;
        }

        pendingQueueHead[finalToken] = head;

        if (finalizedSwapsCount > 0) {
            lastPullFundsBlock[finalToken] = block.number;
        }

        return (finalizedSwapsCount, finalizedSwapsAmount, queue.length - head);
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
        uint128 cloid
    ) external nonReentrant onlyPermissionedBot returns (bytes32 quoteNonce) {
        quoteNonce = cloidToQuoteNonce[cloid];
        PendingSwap storage pendingSwap = pendingSwaps[quoteNonce];
        // A pending swap was enqueued with this Final token, so it had to be set. Unsetting the final token config is not
        // a valid configuration action so we can rely on finalToken being set here
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[pendingSwap.finalToken];

        // Here, cloid == pendingSwap.limitOrderCloid
        finalTokenInfo.swapHandler.cancelOrderByCloid(finalTokenInfo.assetIndex, cloid);
        // Clear out the cloid. `submitUpdatedLimitOrder` function requires that this is empty. Means that no tracked
        // associated limit order is present
        delete pendingSwap.limitOrderCloid;

        emit CancelledLimitOrder(quoteNonce, finalTokenInfo.assetIndex, cloid);
    }

    /**
     * @notice This function is to be used in situations when the limit order that's on the books has become stale and
     * we want to speed up the execution.
     * @dev This function should be called as a second step after the `cancelLimitOrderByCloid` was already called and
     * the order was fully cancelled. It is the responsibility of this function's caller to supply oldPriceX1e8 and
     * oldSizeX1e8Left associated with the previous cancelled order. They act as a safeguarding policy that don't allow
     * to spend more tokens then the previous limit order wanted to spend to protect the accounting assumptions of the
     * current contract. Although the values provided as still fully trusted.
     * @dev This functions chooses to ignore the `maxBpsToSponsor` param as it is supposed to be
     * used only in rare cases. We choose to pay for the adjusted limit order price completely.
     * @param quoteNonce quote nonce is used to uniquely identify user order (PendingSwap)
     * @param priceX1e8 price to set for new limit order
     * @param oldPriceX1e8 price that was set for the cancelled order
     * @param oldSizeX1e8Left size that was remaining on the order that was cancelled
     */
    function submitUpdatedLimitOrder(
        // old order with some price and some out amount expectations: pendingSwaps (minAmountOutCore, totalSponsoredCore)
        // new order with some price and new amount expectations. minAmountOutCore2, totalSponsoredCore + (minAmountOutCore2 - minAmountOutCore)
        // oldPriceX1e8, oldSizeX1e8Left -> partial Limit order that we cancelled
        // how much tokens that we sent in are still there for us to trade?
        // priceX1e8: sz ?
        // partialBudgetRemaining
        bytes32 quoteNonce,
        uint64 priceX1e8,
        uint64 oldPriceX1e8,
        uint64 oldSizeX1e8Left
    ) external nonReentrant onlyPermissionedBot {
        PendingSwap storage pendingSwap = pendingSwaps[quoteNonce];
        require(pendingSwap.limitOrderCloid == 0, "Cannot resubmit LO for non-empty cloid");

        address finalToken = pendingSwap.finalToken;
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[finalToken];
        CoreTokenInfo memory initialTokenInfo = coreTokenInfos[baseToken];
        CoreTokenInfo memory finalTokenCoreInfo = coreTokenInfos[finalToken];

        // Remaining budget of tokens attributable to the "old limit order" (now cancelled)
        uint64 coreBudgetRemaining = _calcRemainingLOBudget(
            oldPriceX1e8,
            oldSizeX1e8Left,
            finalTokenInfo.isBuy,
            finalTokenInfo.feePpm,
            initialTokenInfo,
            finalTokenCoreInfo
        );
        (uint64 szX1e8, , uint64 guaranteedCoreOut) = _calcLOAmounts(
            coreBudgetRemaining,
            priceX1e8,
            finalTokenInfo.isBuy,
            finalTokenInfo.feePpm,
            initialTokenInfo,
            finalTokenCoreInfo
        );

        (, , uint64 guaranteedCoreOutOld) = _calcLOAmounts(
            coreBudgetRemaining,
            oldPriceX1e8,
            finalTokenInfo.isBuy,
            finalTokenInfo.feePpm,
            initialTokenInfo,
            finalTokenCoreInfo
        );

        uint64 sponsorDeltaCore;
        if (guaranteedCoreOut < guaranteedCoreOutOld) {
            sponsorDeltaCore = guaranteedCoreOutOld - guaranteedCoreOut;
        } else {
            sponsorDeltaCore = 0;
            emit BetterPricedLOSubmitted(quoteNonce, oldPriceX1e8, priceX1e8);
        }

        // Submit new Limit Order
        uint128 cloid = ++nextCloid;
        SwapHandler swapHandler = finalTokenInfo.swapHandler;
        swapHandler.submitLimitOrder(finalTokenInfo, priceX1e8, szX1e8, cloid);
        pendingSwap.limitOrderCloid = cloid;

        // Send extra sponsorship money to cover for the guaranteed amount out difference
        if (sponsorDeltaCore > 0) {
            uint256 sponsorDeltaEvm;
            (sponsorDeltaEvm, sponsorDeltaCore) = HyperCoreLib.minimumCoreReceiveAmountToAmounts(
                sponsorDeltaCore,
                finalTokenCoreInfo.tokenInfo.evmExtraWeiDecimals
            );

            _getFromDonationBox(finalToken, sponsorDeltaEvm);
            IERC20(finalToken).safeTransfer(address(swapHandler), sponsorDeltaEvm);
            cumulativeSponsoredAmount[finalToken] += sponsorDeltaEvm;
            if (
                !HyperCoreLib.isCoreAmountSafeToBridge(
                    finalTokenCoreInfo.coreIndex,
                    sponsorDeltaCore,
                    finalTokenCoreInfo.bridgeSafetyBufferCore
                )
            ) {
                // Can't add required sponsored funds to balance out the accounting. Have to revert
                revert("Bridging is unsafe");
            }
            swapHandler.transferFundsToSelfOnCore(
                finalToken,
                finalTokenCoreInfo.coreIndex,
                sponsorDeltaEvm,
                finalTokenCoreInfo.tokenInfo.evmExtraWeiDecimals
            );

            uint64 fullOldGuranteedOut = pendingSwap.minCoreAmountFromLO;
            pendingSwap.minCoreAmountFromLO = fullOldGuranteedOut + guaranteedCoreOut - guaranteedCoreOutOld;
            pendingSwap.sponsoredCoreAmountPreFunded = pendingSwap.sponsoredCoreAmountPreFunded + sponsorDeltaCore;
        }

        emit ReplacedOldLimitOrder(quoteNonce, cloid, priceX1e8, szX1e8, oldPriceX1e8, oldSizeX1e8Left);
    }

    /// @notice Forwards `amount` plus potential sponsorship funds (for bridging fee) to user on HyperEVM
    function _fallbackHyperEVMFlow(
        uint256 amount,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address finalRecipient,
        uint256 extraFeesToSponsor,
        address finalToken
    ) internal virtual {
        uint256 maxEvmAmountToSponsor = ((amount + extraFeesToSponsor) * maxBpsToSponsor) / BPS_SCALAR;
        uint256 sponsorshipFundsToForward = extraFeesToSponsor > maxEvmAmountToSponsor
            ? maxEvmAmountToSponsor
            : extraFeesToSponsor;

        if (!_availableInDonationBox(finalToken, sponsorshipFundsToForward)) {
            sponsorshipFundsToForward = 0;
        }
        if (sponsorshipFundsToForward > 0) {
            _getFromDonationBox(finalToken, sponsorshipFundsToForward);
        }
        uint256 totalAmountToForward = amount + sponsorshipFundsToForward;
        IERC20(finalToken).safeTransfer(finalRecipient, totalAmountToForward);
        cumulativeSponsoredAmount[finalToken] += sponsorshipFundsToForward;
        emit FallbackHyperEVMFlowCompleted(
            quoteNonce,
            finalRecipient,
            finalToken,
            amount,
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

    function _getAccountActivationFeeEVM(address token, address recipient) internal view returns (uint256) {
        bool accountActivated = HyperCoreLib.coreUserExists(recipient);
        return accountActivated ? 0 : coreTokenInfos[token].accountActivationFeeEVM;
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

    // TODO? Alternative flow: make this permissionless, send money SwapHandler @ core -> DonationBox @ core => DonationBox pulls money from Core to Self (needs DonationBox code change)
    function sweepOnCoreFromSwapHandler(address token, uint64 amount) external nonReentrant onlyPermissionedBot {
        // We first want to make sure there are not pending limit orders for this token
        uint256 head = pendingQueueHead[token];
        if (head < pendingQueue[token].length) {
            revert("Cannot sweep on core if there are pending limit orders");
        }

        // Prevent pulling fantom funds (e.g. if finalizePendingSwaps reads stale balance because of this fund pull)
        require(lastPullFundsBlock[token] < block.number, "Can't pull funds twice in the same block");
        lastPullFundsBlock[token] = block.number;

        SwapHandler swapHandler = finalTokenInfos[token].swapHandler;
        swapHandler.transferFundsToUserOnCore(finalTokenInfos[token].assetIndex, msg.sender, amount);
    }

    /// @notice Reads the current spot price from HyperLiquid and applies a configured suggested discount for faster execution
    function _getSuggestedPriceX1e8(
        FinalTokenInfo memory finalTokenInfo
    ) internal view returns (uint64 limitPriceX1e8) {
        uint64 spotX1e8 = HyperCoreLib.spotPx(finalTokenInfo.assetIndex);
        // Buy above spot, sell below spot
        uint256 adjBps = finalTokenInfo.isBuy
            ? (BPS_SCALAR + finalTokenInfo.suggestedDiscountBps)
            : (BPS_SCALAR - finalTokenInfo.suggestedDiscountBps);
        limitPriceX1e8 = uint64((uint256(spotX1e8) * adjBps) / BPS_SCALAR);
    }

    /**************************************
     *    LIMIT ORDER CALCULATION UTILS   *
     **************************************/

    /// @notice Given the size and price of a limit order, returns the remaining `budget` that Limit order expects to spend
    function _calcRemainingLOBudget(
        uint64 pxX1e8,
        uint64 szX1e8,
        bool isBuy,
        uint64 feePpm,
        CoreTokenInfo memory tokenHave,
        CoreTokenInfo memory tokenWant
    ) internal pure returns (uint64 budget) {
        CoreTokenInfo memory _quoteToken = isBuy ? tokenHave : tokenWant;
        CoreTokenInfo memory _baseToken = isBuy ? tokenWant : tokenHave;

        if (isBuy) {
            // We have quoteTokens. Estimate how many quoteTokens we are GUARANTEED to have had to enqueue the LO in the first place (proportional)
            // qTR is quote tokens real. qTD quote token decimals.
            // szX1e8 * pxX1e8 / 10 ** 8 = qTX1e8Net
            // qTR * 10 ** 8 * (10 ** 6 - feePpm) / (10 ** 6 * 10 ** qTD) = qTX1e8Net
            // qTR = szX1e8 * pxX1e8 * 10 ** 6 * 10 ** qTD / (10 ** 8 * 10 ** 8 * (10 ** 6 - feePpm))
            budget = uint64(
                (uint256(szX1e8) * uint256(pxX1e8) * PPM_SCALAR * 10 ** (_quoteToken.tokenInfo.weiDecimals)) /
                    (10 ** 16 * (PPM_SCALAR - feePpm))
            );
        } else {
            // We have baseTokens. Convert `szX1e8` to base token budget. A simple decimals conversion here
            budget = uint64((szX1e8 * 10 ** (_baseToken.tokenInfo.weiDecimals)) / 10 ** 8);
        }
    }

    /**
     * @notice The purpose of this function is best described by its return params. Given a budget and a price, determines
     * size to set, tokens to send, and min amount received.
     * @return szX1e8 size value to supply when sending a limit order to HyperCore
     * @return coreToSend the number of tokens to send for this trade to suceed; <= coreBudget
     * @return guaranteedCoreOut the ABSOLUTE MINIMUM that we're guaranteed to receive when the limit order fully settles
     */
    function _calcLOAmounts(
        uint64 coreBudget,
        uint64 pxX1e8,
        bool isBuy,
        uint64 feePpm,
        CoreTokenInfo memory tokenHave,
        CoreTokenInfo memory tokenWant
    ) internal pure returns (uint64 szX1e8, uint64 coreToSend, uint64 guaranteedCoreOut) {
        if (isBuy) {
            return
                _calcLOAmountsBuy(
                    coreBudget,
                    pxX1e8,
                    tokenHave.tokenInfo.weiDecimals,
                    tokenHave.tokenInfo.szDecimals,
                    tokenWant.tokenInfo.weiDecimals,
                    tokenWant.tokenInfo.szDecimals,
                    feePpm
                );
        } else {
            return
                _calcLOAmountsSell(
                    coreBudget,
                    pxX1e8,
                    tokenWant.tokenInfo.weiDecimals,
                    tokenWant.tokenInfo.szDecimals,
                    tokenHave.tokenInfo.weiDecimals,
                    tokenHave.tokenInfo.szDecimals,
                    feePpm
                );
        }
    }

    /**
     * @notice Given the quote budget and the price, this function calculates the size of the buy limit order to set
     * as well as the minimum amount of out token to expect. This calculation is based on the HIP-1 spot trading formula.
     * Source: https://hyperliquid.gitbook.io/hyperliquid-docs/hyperliquid-improvement-proposals-hips/hip-1-native-token-standard#spot-trading
     * @param quoteBudget The budget of the quote in base token.
     * @param pxX1e8 The price of the quote token in base token.
     * @param quoteD The decimals of the quote token.
     * @param quoteSz The size decimals of the quote token.
     * @param baseD The decimals of the base token.
     * @param baseSz The size decimals of the base token.
     * @param feePpm The fee in ppm that is applied to the quote.
     * @return szX1e8 The size of the limit order to set.
     * @return tokensToSendCore The number of tokens to send for this trade to suceed.
     * @return minAmountOutCore The minimum amount of out token to expect.
     */
    function _calcLOAmountsBuy(
        uint64 quoteBudget,
        uint64 pxX1e8,
        uint8 quoteD,
        uint8 quoteSz,
        uint8 baseD,
        uint8 baseSz,
        uint64 feePpm
    ) internal pure returns (uint64 szX1e8, uint64 tokensToSendCore, uint64 minAmountOutCore) {
        uint256 px = (pxX1e8 * 10 ** (PX_D + quoteSz)) / 10 ** (8 + baseSz);
        // quoteD >= quoteSz always
        uint256 sz = (quoteBudget * (PPM_SCALAR - feePpm) * 10 ** PX_D) / (PPM_SCALAR * px * 10 ** (quoteD - quoteSz));
        // baseD >= baseSz always
        uint64 outBaseNet = uint64(sz * 10 ** (baseD - baseSz));
        szX1e8 = uint64((uint256(outBaseNet) * 10 ** 8) / 10 ** baseD);
        tokensToSendCore = quoteBudget;
        minAmountOutCore = outBaseNet;
    }

    /**
     * @notice Given the quote budget and the price, this function calculates the size of the sell limit order to set
     * as well as the minimum amount of out token to expect. This calculation is based on the HIP-1 spot trading formula.
     * Source: https://hyperliquid.gitbook.io/hyperliquid-docs/hyperliquid-improvement-proposals-hips/hip-1-native-token-standard#spot-trading
     * @param baseBudget The budget of the quote in base token.
     * @param pxX1e8 The price of the quote token in base token.
     * @param quoteD The decimals of the quote token.
     * @param quoteSz The size decimals of the quote token.
     * @param baseD The decimals of the base token.
     * @param baseSz The size decimals of the base token.
     * @param feePpm The fee in ppm that is applied to the quote.
     * @return szX1e8 The size of the limit order to set.
     * @return tokensToSendCore The number of tokens to send for this trade to suceed.
     * @return minAmountOutCore The minimum amount of out token to expect.
     */
    function _calcLOAmountsSell(
        uint64 baseBudget,
        uint64 pxX1e8,
        uint8 quoteD,
        uint8 quoteSz,
        uint8 baseD,
        uint8 baseSz,
        uint64 feePpm
    ) internal pure returns (uint64 szX1e8, uint64 tokensToSendCore, uint64 minAmountOutCore) {
        uint64 sz = uint64(baseBudget / 10 ** (baseD - baseSz));
        uint256 px = (pxX1e8 * 10 ** (PX_D + quoteSz)) / 10 ** (8 + baseSz);

        // quoteD >= quoteSz always
        uint64 outQuoteGross = uint64((px * sz * 10 ** (quoteD - quoteSz)) / 10 ** PX_D);
        uint64 outQuoteNet = uint64((outQuoteGross * (PPM_SCALAR - feePpm)) / PPM_SCALAR);
        szX1e8 = uint64((sz * 10 ** 8) / 10 ** baseSz);
        tokensToSendCore = baseBudget;
        minAmountOutCore = outQuoteNet;
    }
}
