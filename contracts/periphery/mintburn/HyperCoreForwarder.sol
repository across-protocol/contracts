//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20Metadata, IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { DonationBox } from "../../chain-adapters/DonationBox.sol";
import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { CoreTokenInfo } from "./Structs.sol";
import { FinalTokenInfo } from "./Structs.sol";
import { SwapHandler } from "./SwapHandler.sol";

contract HyperCoreForwarder is AccessControl {
    using SafeERC20 for IERC20;

    uint256 public constant CORE_DECIMALS = 8;
    uint256 public constant BPS_DECIMALS = 4;
    uint256 public constant PPM_DECIMALS = 6;
    uint256 public constant CORE_SCALAR = 10 ** CORE_DECIMALS;
    uint256 public constant BPS_SCALAR = 10 ** BPS_DECIMALS;
    uint256 public constant PPM_SCALAR = 10 ** PPM_DECIMALS;

    uint256 public constant BRIDGE_BALANCE_BUFFER_EVM = 10 ** 9; // 1,000,000,000 (1 billion)

    // Roles
    bytes32 public constant LIMIT_ORDER_UPDATER_ROLE = keccak256("LIMIT_ORDER_UPDATER_ROLE");

    /// @notice The donation box contract.
    DonationBox public immutable donationBox;

    /// @notice A mapping of token addresses to their core token info.
    mapping(address => CoreTokenInfo) public coreTokenInfos;

    /// @notice A mapping of token address to additional relevan info for final tokens, like Hyperliquid market params
    mapping(address => FinalTokenInfo) public finalTokenInfos;

    /// @notice All operations performed in this contract are relative to this baseToken
    address immutable baseToken;

    /// @notice A struct used for storing state of a swap flow that has been initialized, but not yet finished
    struct PendingSwap {
        address finalRecipient;
        address finalToken;
        /// @notice totalCoreAmountToForwardToUser = minCoreAmountFromLO + sponsoredCoreAmountPreFunded always.
        uint64 minCoreAmountFromLO;
        uint64 sponsoredCoreAmountPreFunded;
        uint128 limitOrderCloid;
    }

    // quoteNonce => pending swap details
    mapping(bytes32 => PendingSwap) public pendingSwaps;
    // finalToken => queue of quote nonces
    mapping(address => bytes32[]) public pendingQueue;
    // finalToken => current head index in queue
    mapping(address => uint256) public pendingQueueHead;

    /// @notice Used for uniquely identifying Limit Orders this contract submits. Monotonically increasing
    uint128 public nextCloid;

    /// @notice A mapping from limit order cliod to the quoteNonce (user order id) responsible for submitting the LO
    mapping(uint128 => bytes32) public cloidToQuoteNonce;

    /// @notice Emitted when the donation box is insufficient funds.
    event DonationBoxInsufficientFunds(address token, uint256 amount);

    /// @notice Emitted when the donation box is insufficient funds and we can't proceed.
    error DonationBoxInsufficientFundsError(address token, uint256 amount);

    /// @notice Emitted when a simple transfer to core is executed.
    event SimpleTransferFlowCompleted(
        bytes32 quoteNonce,
        uint256 finalAmount,
        uint256 amountSponsored,
        address finalRecipient,
        address finalToken
    );

    event SwapFlowInitialized(
        bytes32 quoteNonce,
        uint256 receivedTokensEvm,
        uint256 sponsoredTokensEvm,
        address finalRecipient,
        address finalToken
    );

    event SwapFlowCompleted(bytes32 quoteNonce, uint64 amountCore, address user, address finalToken);

    event FallbackHyperEVMFlowCompleted(
        bytes32 quoteNonce,
        uint256 receivedTokensEvm,
        uint256 sponsoredTokensEvm,
        address finalRecipient,
        address finalToken
    );

    event CancelledLimitOrder(bytes32 quoteNonce, uint32 asset, uint128 cloid);

    event UpdatedLimitOrder(
        bytes32 quoteNonce,
        uint64 priceX1e8,
        uint64 sizeX1e8,
        uint64 oldPriceX1e8,
        uint64 oldSizeX1e8Left
    );

    /**************************************
     *            MODIFIERS               *
     **************************************/

    modifier onlyDefaultAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not default admin");
        _;
    }

    modifier onlyLimitOrderUpdater() {
        require(hasRole(LIMIT_ORDER_UPDATER_ROLE, msg.sender), "Not limit order updater");
        _;
    }

    modifier onlyExistingToken(address evmTokenAddress) {
        require(coreTokenInfos[evmTokenAddress].tokenInfo.evmContract != address(0), "Unknown token");
        _;
    }

    /**
     *
     * @param _donationBox Sponsorship funds live here
     * @param _baseToken Main token used with this Forwarder
     * @param _coreIndex HCore index of baseToken
     * @param _canBeUsedForAccountActivation Whether or not baseToken can be used for account activation fee on HCore
     * @param _accountActivationFeeCore Fee amount to pay for account activation
     */
    constructor(
        address _donationBox,
        address _baseToken,
        uint32 _coreIndex,
        bool _canBeUsedForAccountActivation,
        uint64 _accountActivationFeeCore
    ) {
        donationBox = DonationBox(_donationBox);
        // @dev initialize this to 1 as to save 0 for special events when "no cloid is set" = no associated limit order
        nextCloid = 1;

        _setCoreTokenInfo(_baseToken, _coreIndex, _canBeUsedForAccountActivation, _accountActivationFeeCore);
        baseToken = _baseToken;
    }

    /**************************************
     *      CONFIGURATION FUNCTIONS       *
     **************************************/

    // TODO: do we allow unsetting the core token info?
    function setCoreTokenInfo(
        address token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore
    ) external onlyDefaultAdmin {
        _setCoreTokenInfo(token, coreIndex, canBeUsedForAccountActivation, accountActivationFeeCore);
    }

    // TODO: do we allow unsetting the params?
    /**
     * @notice Sets the parameters for a final token.
     * @dev This function deploys a new SwapHandler contract if one is not already set. If the final token
     * can't be used for account activation, the handler will be left unactivated and would need to be activated by the caller.
     * @param finalToken The address of the final token.
     * @param assetIndex The index of the asset in the Hyperliquid market.
     * @param isBuy Whether the final token is a buy or a sell.
     * @param feePpm The fee in parts per million.
     * @param suggestedSlippageBps The suggested slippage in basis points.
     */
    function setFinalTokenParams(
        address finalToken,
        uint32 assetIndex,
        bool isBuy,
        uint32 feePpm,
        uint32 suggestedSlippageBps
    ) external onlyExistingToken(finalToken) onlyDefaultAdmin {
        CoreTokenInfo memory coreTokenInfo = coreTokenInfos[finalToken];

        SwapHandler swapHandler = finalTokenInfos[finalToken].swapHandler;
        if (address(swapHandler) == address(0)) {
            swapHandler = new SwapHandler();
        }

        finalTokenInfos[finalToken] = FinalTokenInfo({
            assetIndex: assetIndex,
            isBuy: isBuy,
            feePpm: feePpm,
            swapHandler: swapHandler,
            suggestedSlippageBps: suggestedSlippageBps
        });

        uint256 accountActivationFee = _getAccountActivationFeeEVM(finalToken, address(swapHandler));

        if (accountActivationFee > 0 && coreTokenInfo.canBeUsedForAccountActivation) {
            _getFromDonationBox(finalToken, accountActivationFee);
            IERC20(finalToken).safeTransfer(address(swapHandler), accountActivationFee);
            swapHandler.activateCoreAccount(
                finalToken,
                coreTokenInfo.coreIndex,
                accountActivationFee,
                coreTokenInfo.tokenInfo.evmExtraWeiDecimals
            );
        }
    }

    /**
     * @notice This function is to be called by an inheriting contract. It is to be called after the child contract
     * checked the API signature and made sure that the params passed here have been verified by either the underlying
     * bridge mechanics, or API signaure, or both.
     */
    function _executeFlow(
        uint256 amount,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address finalRecipient,
        address finalToken,
        uint256 extraFeesToSponsor
    ) internal {
        if (finalToken == baseToken) {
            _executeSimpleTransferFlow(
                amount,
                quoteNonce,
                maxBpsToSponsor,
                finalRecipient,
                finalToken,
                extraFeesToSponsor
            );
        } else {
            // @dev Notice, swap flow doesn't use `extraFeesToSponsor` because it's sponsorship is calculated based on
            // the swap output amount anyway. So we don't have to sponsor the extra fees separately (like CCTP bridge fees)
            _initiateSwapFlow(amount, quoteNonce, finalRecipient, finalToken, maxBpsToSponsor);
        }
    }

    function _executeSimpleTransferFlow(
        uint256 amount,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address finalRecipient,
        address finalToken,
        uint256 extraFeesToSponsor
    ) internal {
        CoreTokenInfo storage coreTokenInfo = coreTokenInfos[finalToken];

        uint256 accountCreationFee = _getAccountActivationFeeEVM(finalToken, finalRecipient);
        uint256 maxFee = (amount * maxBpsToSponsor) / BPS_SCALAR;
        uint256 amountToSponsor = extraFeesToSponsor + accountCreationFee;
        if (amountToSponsor > maxFee) {
            amountToSponsor = maxFee;
        }

        if (amountToSponsor > 0) {
            if (!_tryGetFromDonationBox(coreTokenInfo.tokenInfo.evmContract, amountToSponsor)) {
                amountToSponsor = 0;
            }
        }

        uint256 finalAmount = amount + amountToSponsor;

        // If there are no funds left on the destination side of the bridge, the funds will be lost in the
        // bridge. To prevent this, we add a buffer to the final amount.
        uint256 finalTokenDecimals = IERC20Metadata(finalToken).decimals();
        uint256 finalAmountWithBuffer = finalAmount + BRIDGE_BALANCE_BUFFER_EVM * 10 ** finalTokenDecimals;
        bool isSafe = HyperCoreLib.isAmountSafeToBridge(
            finalRecipient,
            coreTokenInfo.coreIndex,
            finalAmountWithBuffer,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        // If the amount is not safe to bridge or the user has no HyperCore account and we can't sponsor its creation;
        // fall back to sending user funds on HyperEVM.
        if (!isSafe || (accountCreationFee > 0 && !coreTokenInfo.canBeUsedForAccountActivation)) {
            _sendUserFundsOnHyperEVM(quoteNonce, finalAmount, finalRecipient, finalToken);
            return;
        }

        // There is a very slim chance that by the time we get here, the balance of the bridge changes
        // and the funds are lost.
        HyperCoreLib.transferERC20EVMToCore(
            finalToken,
            coreTokenInfo.coreIndex,
            finalRecipient,
            finalAmount,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
        emit SimpleTransferFlowCompleted(quoteNonce, finalAmount, amountToSponsor, finalRecipient, finalToken);
    }

    function _getAccountActivationFeeEVM(address token, address recipient) internal view returns (uint256) {
        bool accountActivated = HyperCoreLib.coreUserExists(recipient);

        return accountActivated ? 0 : coreTokenInfos[token].accountActivationFeeEVM;
    }

    function _initiateSwapFlow(
        uint256 amountLD,
        bytes32 quoteNonce,
        address finalUser,
        address finalToken,
        uint256 maxBpsToSponsor
    ) internal {
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[finalToken];

        require(address(finalTokenInfo.swapHandler) != address(0), "Final token not registered");

        address initialToken = baseToken;
        CoreTokenInfo memory initialCoreTokenInfo = coreTokenInfos[initialToken];
        CoreTokenInfo memory finalCoreTokenInfo = coreTokenInfos[finalToken];

        (uint256 quotedEvmAmount, uint64 quotedCoreAmount) = HyperCoreLib.maximumEVMSendAmountToAmounts(
            amountLD,
            initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        uint64 coreAmountIn = uint64(quotedCoreAmount);

        // X1e8 = Hyperliquid price units
        uint64 spotX1e8 = HyperCoreLib.spotPx(finalTokenInfo.assetIndex);
        // Directional limit price for faster fills: buy above spot, sell below spot
        uint256 adjBps = finalTokenInfo.isBuy
            ? (BPS_SCALAR + finalTokenInfo.suggestedSlippageBps)
            : (BPS_SCALAR - finalTokenInfo.suggestedSlippageBps);
        uint64 limitPriceX1e8 = uint64((uint256(spotX1e8) * adjBps) / BPS_SCALAR);

        // Compute min expected out on Core in final token units
        // - If buying, finalToken is base: baseOut = quoteIn / price, less fee
        // - If selling, finalToken is quote: quoteOut = baseIn * price, less fee
        uint64 minOutCore;
        if (finalTokenInfo.isBuy) {
            uint256 grossBaseOut = (uint256(coreAmountIn) * CORE_SCALAR) / uint256(limitPriceX1e8);
            uint256 netBaseOut = (grossBaseOut * (PPM_SCALAR - finalTokenInfo.feePpm)) / PPM_SCALAR;
            minOutCore = uint64(netBaseOut);
        } else {
            uint256 grossQuoteOut = (uint256(coreAmountIn) * uint256(limitPriceX1e8)) / CORE_SCALAR;
            uint256 netQuoteOut = (grossQuoteOut * (PPM_SCALAR - finalTokenInfo.feePpm)) / PPM_SCALAR;
            minOutCore = uint64(netQuoteOut);
        }

        uint64 accountCreationFee = uint64(_getAccountActivationFeeEVM(finalToken, finalUser));

        // @dev the user has no HyperCore account and we can't sponsor its creation; fall back to sending user funds on
        // HyperEVM
        if (accountCreationFee > 0 && !finalCoreTokenInfo.canBeUsedForAccountActivation) {
            _sendUserFundsOnHyperEVM(quoteNonce, amountLD, finalUser, finalToken);
            return;
        }

        uint64 oneToOneSendAmount = quotedCoreAmount + accountCreationFee;
        uint64 totalCoreAmountToSponsor = oneToOneSendAmount - minOutCore;
        uint64 allowedCoreAmountToSponsor = uint64((uint256(quotedCoreAmount) * maxBpsToSponsor) / BPS_SCALAR);

        if (totalCoreAmountToSponsor > allowedCoreAmountToSponsor) {
            totalCoreAmountToSponsor = allowedCoreAmountToSponsor;
        }

        uint256 totalEVMAmountToSponsor;
        (totalEVMAmountToSponsor, totalCoreAmountToSponsor) = HyperCoreLib.minimumCoreReceiveAmountToAmounts(
            totalCoreAmountToSponsor,
            finalCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        if (totalEVMAmountToSponsor > 0) {
            // On success, we have totalEVMAmountToSponsor + quoted.evm on balance. Otherwise, set sponsored amts to 0
            if (!_tryGetFromDonationBox(finalToken, totalEVMAmountToSponsor)) {
                totalEVMAmountToSponsor = 0;
                totalCoreAmountToSponsor = 0;
            }
        }

        // Transfer funds to SwapHandler @ core
        SwapHandler swapHandler = finalTokenInfo.swapHandler;

        // TODO: check first, that we're able to bridge both amounts. If not, send user funds on HyperEVM instead

        // 1. Fund SwapHandler @ core with `initialToken`: use it for the trade
        if (quotedEvmAmount > 0) {
            IERC20(initialToken).safeTransfer(address(swapHandler), quotedEvmAmount);
            swapHandler.transferFundsToSelfOnCore(
                initialToken,
                initialCoreTokenInfo.coreIndex,
                quotedEvmAmount,
                initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
            );
        }

        // 2. Fund SwapHandler @ core with `finalToken`: use that for sponsorship
        if (totalEVMAmountToSponsor > 0) {
            IERC20(finalToken).safeTransfer(address(swapHandler), totalEVMAmountToSponsor);
            swapHandler.transferFundsToSelfOnCore(
                finalToken,
                finalCoreTokenInfo.coreIndex,
                totalEVMAmountToSponsor,
                finalCoreTokenInfo.tokenInfo.evmExtraWeiDecimals
            );
        }

        // Order size in 1e8 units. Ensure we never spend more than coreAmountIn on the quote side for buys.
        uint64 sizeX1e8;
        if (finalTokenInfo.isBuy) {
            // Buying: calculate base asset amount we're safe to set when initial token is quote asset
            uint256 pxWithFeeX1e8 = (uint256(limitPriceX1e8) * (PPM_SCALAR + finalTokenInfo.feePpm)) / PPM_SCALAR;
            sizeX1e8 = uint64((uint256(coreAmountIn) * CORE_SCALAR) / pxWithFeeX1e8);
        } else {
            // Selling: sell exactly `coreAmountIn` of base asset
            sizeX1e8 = coreAmountIn;
        }

        // TODO: leave this check?
        // If computed size rounds to zero, fall back
        if (sizeX1e8 == 0) {
            _sendUserFundsOnHyperEVM(quoteNonce, amountLD, finalUser, finalToken);
            return;
        }
        uint128 cloid = ++nextCloid;
        swapHandler.submitLimitOrder(finalTokenInfo, limitPriceX1e8, sizeX1e8, cloid);

        pendingSwaps[quoteNonce] = PendingSwap({
            finalRecipient: finalUser,
            finalToken: finalToken,
            minCoreAmountFromLO: minOutCore,
            sponsoredCoreAmountPreFunded: totalCoreAmountToSponsor,
            limitOrderCloid: cloid
        });
        pendingQueue[finalToken].push(quoteNonce);
        cloidToQuoteNonce[cloid] = quoteNonce;

        emit SwapFlowInitialized(quoteNonce, amountLD, totalEVMAmountToSponsor, finalUser, finalToken);
    }

    function _finalizePendingSwaps(address finalToken, uint256 maxToProcess) internal {
        CoreTokenInfo memory coreTokenInfo = coreTokenInfos[finalToken];
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[finalToken];

        require(address(finalTokenInfo.swapHandler) != address(0), "Final token not registered");

        uint256 head = pendingQueueHead[finalToken];
        bytes32[] storage queue = pendingQueue[finalToken];
        if (head >= queue.length || maxToProcess == 0) return;

        // Note: `availableCore` is the SwapHandler's Core balance for `finalToken`, which monotonically increases
        uint64 availableCore = HyperCoreLib.spotBalance(address(finalTokenInfo.swapHandler), coreTokenInfo.coreIndex);
        uint256 processed = 0;

        while (head < queue.length && processed < maxToProcess) {
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
                totalAmountToForwardToUser,
                pendingSwap.finalRecipient,
                pendingSwap.finalToken
            );

            availableCore -= totalAmountToForwardToUser;

            // ! @dev Don't delete `pendingSwaps` state because that is used for accounting calculations
            // delete pendingSwaps[nonce];
            head += 1;
            processed += 1;
        }
    }

    function cancelLimitOrderByCloid(uint32 cloid) external onlyLimitOrderUpdater returns (bytes32 quoteNonce) {
        quoteNonce = cloidToQuoteNonce[cloid];
        PendingSwap storage pendingSwap = pendingSwaps[quoteNonce];

        address finalTokenAddress = pendingSwap.finalToken;
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[finalTokenAddress];

        finalTokenInfo.swapHandler.cancelOrderByCloid(finalTokenInfo.assetIndex, pendingSwap.limitOrderCloid);
        // @dev clear out the cloid. `submitUpdatedLimitOrder` function requires that this is empty. Means that no tracked
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
     * @param sizeX1e8 size to set for new limit order
     * @param oldPriceX1e8 price that was set for the cancelled order
     * @param oldSizeX1e8Left size that was remaining on the order that was cancelled
     */
    function submitUpdatedLimitOrder(
        bytes32 quoteNonce,
        uint64 priceX1e8,
        uint64 sizeX1e8,
        uint64 oldPriceX1e8,
        uint64 oldSizeX1e8Left
    ) external onlyLimitOrderUpdater {
        PendingSwap storage pendingSwap = pendingSwaps[quoteNonce];
        require(pendingSwap.limitOrderCloid == 0, "Cannot resubmit LO for non-empty cloid");

        address finalToken = pendingSwap.finalToken;
        FinalTokenInfo memory finalTokenInfo = finalTokenInfos[finalToken];
        CoreTokenInfo memory coreTokenInfo = coreTokenInfos[finalToken];

        // Enforce that the new order does not require more tokens than the remaining budget of the previous order
        if (finalTokenInfo.isBuy) {
            // New required quote with fee, rounded up
            // notionalCore = ceil(size * price / 1e8)
            uint256 notionalCore = (uint256(sizeX1e8) * uint256(priceX1e8) + CORE_SCALAR - 1) / CORE_SCALAR;
            uint256 requiredQuoteWithFeeCore = (notionalCore * (PPM_SCALAR + finalTokenInfo.feePpm) + PPM_SCALAR - 1) /
                PPM_SCALAR;

            // Old remaining budget in quote with fee, rounded down
            uint256 oldNotionalCore = (uint256(oldSizeX1e8Left) * uint256(oldPriceX1e8)) / CORE_SCALAR;
            uint256 oldBudgetWithFeeCore = (oldNotionalCore * (PPM_SCALAR + finalTokenInfo.feePpm)) / PPM_SCALAR;

            require(requiredQuoteWithFeeCore <= oldBudgetWithFeeCore, "ExceedsRemainingQuoteBudget");
        } else {
            // Selling base: ensure we don't sell more base than remaining
            require(sizeX1e8 <= oldSizeX1e8Left, "ExceedsRemainingBaseSize");
        }

        uint128 cloid = ++nextCloid;
        SwapHandler swapHandler = finalTokenInfo.swapHandler;
        swapHandler.submitLimitOrder(finalTokenInfo, priceX1e8, sizeX1e8, cloid);
        pendingSwap.limitOrderCloid = cloid;

        // Recalculate the expected minimum out on Core (in final token units, 1e8 scaling)
        // Respect buy/sell semantics:
        // - If buying, final token is base: minOut ~= size (conservatively minus fee)
        // - If selling, final token is quote: minOut = size * price (minus fee)
        uint64 oldMinCoreAmountFromLO = pendingSwap.minCoreAmountFromLO;
        uint64 newMinCoreAmountFromLO;
        if (finalTokenInfo.isBuy) {
            // Conservative: subtract fee from base received
            uint256 netBaseOut = (uint256(sizeX1e8) * (PPM_SCALAR - finalTokenInfo.feePpm)) / PPM_SCALAR;
            newMinCoreAmountFromLO = uint64(netBaseOut);
        } else {
            uint256 grossQuoteOut = (uint256(sizeX1e8) * uint256(priceX1e8)) / CORE_SCALAR;
            uint256 netQuoteOut = (grossQuoteOut * (PPM_SCALAR - finalTokenInfo.feePpm)) / PPM_SCALAR;
            newMinCoreAmountFromLO = uint64(netQuoteOut);
        }

        // Do not allow improving minOut (would require clawing back sponsorship)
        if (newMinCoreAmountFromLO > oldMinCoreAmountFromLO) {
            revert("Can't resubmit with better price");
        }

        // Keep totalCoreAmountToForwardToUser constant by topping up sponsorship by the decrease in minOut
        uint64 delta = oldMinCoreAmountFromLO - newMinCoreAmountFromLO;
        if (delta > 0) {
            uint256 deltaEvmAmount;
            (deltaEvmAmount, delta) = HyperCoreLib.minimumCoreReceiveAmountToAmounts(
                delta,
                coreTokenInfo.tokenInfo.evmExtraWeiDecimals
            );

            _getFromDonationBox(finalToken, deltaEvmAmount);
            IERC20(finalToken).safeTransfer(address(swapHandler), deltaEvmAmount);
            // TODO: check the bridge balance first, otherwise revert
            swapHandler.transferFundsToSelfOnCore(
                finalToken,
                coreTokenInfo.coreIndex,
                deltaEvmAmount,
                coreTokenInfo.tokenInfo.evmExtraWeiDecimals
            );

            pendingSwap.minCoreAmountFromLO = newMinCoreAmountFromLO;
            pendingSwap.sponsoredCoreAmountPreFunded = pendingSwap.sponsoredCoreAmountPreFunded + delta;
        }

        emit UpdatedLimitOrder(quoteNonce, priceX1e8, sizeX1e8, oldPriceX1e8, oldSizeX1e8Left);
    }

    /**
     *
     * @notice Should be used for rare cases where we can't proceed with our normal HyperCore flows: either there are
     * no funds in the spot bridge, or e.g. we can't pay for account creation for the user for some reason
     */
    function _sendUserFundsOnHyperEVM(
        bytes32 quoteNonce,
        uint256 amountLD,
        address finalUser,
        address finalToken
    ) internal {
        IERC20(finalToken).safeTransfer(finalUser, amountLD);
        emit FallbackHyperEVMFlowCompleted(quoteNonce, amountLD, 0, finalUser, finalToken);
    }

    function _setCoreTokenInfo(
        address token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore
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
            accountActivationFeeCore: accountActivationFeeCore
        });
    }

    /// @notice Gets `amount` of `token` from donationBox. Reverts if unsuccessful
    function _getFromDonationBox(address token, uint256 amount) internal {
        if (!_tryGetFromDonationBox(token, amount)) {
            revert DonationBoxInsufficientFundsError(token, amount);
        }
    }

    /// @notice Tries to get `amount` of `token` from donationBox. Returns false on failure
    function _tryGetFromDonationBox(address token, uint256 amount) internal returns (bool success) {
        try donationBox.withdraw(IERC20(token), amount) {
            success = true;
        } catch {
            emit DonationBoxInsufficientFunds(token, amount);
            success = false;
        }
    }
}
