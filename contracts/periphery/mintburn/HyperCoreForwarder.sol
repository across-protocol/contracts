//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { DonationBox } from "../../chain-adapters/DonationBox.sol";
import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { CoreTokenInfo } from "./Structs.sol";
import { FinalTokenParams } from "./Structs.sol";
import { SwapHandler } from "./SwapHandler.sol";

contract HyperCoreForwarder is AccessControl {
    using SafeERC20 for IERC20;

    uint256 public constant CORE_DECIMALS = 8;
    uint256 public constant BPS_DECIMALS = 4;
    uint256 public constant PPM_DECIMALS = 6;
    uint256 public constant CORE_SCALAR = 10 ** CORE_DECIMALS;
    uint256 public constant BPS_SCALAR = 10 ** BPS_DECIMALS;
    uint256 public constant PPM_SCALAR = 10 ** PPM_DECIMALS;

    // Roles
    bytes32 public constant LIMIT_ORDER_UPDATER_ROLE = keccak256("LIMIT_ORDER_UPDATER_ROLE");

    /// @notice The donation box contract.
    DonationBox public immutable donationBox;

    /// @notice A mapping of token addresses to their core token info.
    mapping(address => CoreTokenInfo) public coreTokenInfos;

    mapping(address => FinalTokenParams) public finalTokenParams;

    struct PendingSwap {
        address finalRecipient;
        address finalToken;
        // @dev totalCoreAmountToForwardToUser = minCoreAmountFromLO + sponsoredCoreAmountPreFunded always.
        // ! When offchain bot is updating a limit order associated with this Pending Order, it's a responsibility of
        // the function ~.updateLimitOrderPrice() to make sure we NEVER DECREASE the `totalCoreAmountToForwardToUser`
        // even for the already "completed" PendingSwaps. The reason is, the settlement of ALL orders depends on the
        // consistency of the `totalCoreAmountToForwardToUser`.
        // As a side note, if we're calling .updateLimitOrderPrice() for the unfinalized user order, we may decrease
        // the `totalCoreAmountToForwardToUser`. If it's finalized, we can't (other orders depend on it)
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

    uint128 public nextCloid;

    mapping(uint128 => bytes32) public cloidToQuoteNonce;

    /// @notice Emitted when the donation box is insufficient funds.
    event DonationBoxInsufficientFunds(address token, uint256 amount);

    /// @notice Emitted when a simple transfer to core is executed.
    event SimpleTransferToCore(
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

    event FallbackHyperEVMFlowExecuted(
        bytes32 quoteNonce,
        uint256 receivedTokensEvm,
        uint256 sponsoredTokensEvm,
        address finalRecipient,
        address finalToken
    );

    event SwapFinalized(bytes32 quoteNonce, uint64 amountCore, address user, address finalToken);

    /**************************************
     *            MODIFIERS               *
     **************************************/

    modifier onlyDefaultAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not default admin");
        _;
    }

    modifier onlyExistingToken(address evmTokenAddress) {
        require(coreTokenInfos[evmTokenAddress].tokenInfo.evmContract != address(0), "Unknown token");
        _;
    }

    constructor(address _donationBox) {
        donationBox = DonationBox(_donationBox);
    }

    function setCoreTokenInfo(
        address finalToken,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint256 accountActivationFee
    ) external onlyDefaultAdmin {
        HyperCoreLib.TokenInfo memory tokenInfo = HyperCoreLib.tokenInfo(coreIndex);
        require(tokenInfo.evmContract == finalToken, "Token mismatch");

        coreTokenInfos[finalToken] = CoreTokenInfo({
            tokenInfo: tokenInfo,
            coreIndex: coreIndex,
            canBeUsedForAccountActivation: canBeUsedForAccountActivation,
            accountActivationFee: accountActivationFee,
            // TODO: convert this to core units using utils from HyperCoreLib
            accountActivationFeeCore: uint64(accountActivationFee)
        });
    }

    function setFinalTokenParams(
        address finalToken,
        uint32 assetIndex,
        bool isBuy,
        uint32 feePpm,
        uint32 suggestedSlippageBps
    ) external onlyExistingToken(finalToken) onlyDefaultAdmin {
        CoreTokenInfo memory coreTokenInfo = coreTokenInfos[finalToken];

        SwapHandler swapHandler = finalTokenParams[finalToken].swapHandler;
        if (address(swapHandler) == address(0)) {
            swapHandler = new SwapHandler();
        }

        finalTokenParams[finalToken] = FinalTokenParams({
            assetIndex: assetIndex,
            isBuy: isBuy,
            feePpm: feePpm,
            swapHandler: swapHandler,
            suggestedSlippageBps: suggestedSlippageBps
        });

        uint256 accountActivationFee = _getAccountActivationFee(finalToken, address(swapHandler));

        if (accountActivationFee > 0) {
            try donationBox.withdraw(IERC20(finalToken), accountActivationFee) {
                IERC20(finalToken).safeTransfer(address(swapHandler), accountActivationFee);
                // Bridge to the SwapHandler Core account
                swapHandler.activateCoreAccount(
                    finalToken,
                    coreTokenInfo.coreIndex,
                    accountActivationFee,
                    coreTokenInfo.tokenInfo.evmExtraWeiDecimals
                );
            } catch {
                emit DonationBoxInsufficientFunds(finalToken, accountActivationFee);
            }
        }
    }

    function _executeSimpleTransferToCore(
        uint256 amount,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address finalRecipient,
        address finalToken,
        uint256 extraFeesToSponsor
    ) internal {
        CoreTokenInfo storage coreTokenInfo = coreTokenInfos[finalToken];

        uint256 maxFee = (amount * maxBpsToSponsor) / BPS_SCALAR;
        uint256 accountActivationFee = _getAccountActivationFee(finalToken, finalRecipient);
        uint256 amountToSponsor = extraFeesToSponsor + accountActivationFee;
        if (amountToSponsor > maxFee) {
            amountToSponsor = maxFee;
        }

        if (amountToSponsor > 0) {
            try donationBox.withdraw(IERC20(coreTokenInfo.tokenInfo.evmContract), amountToSponsor) {
                // success: full sponsorship amount withdrawn to this contract
            } catch {
                emit DonationBoxInsufficientFunds(coreTokenInfo.tokenInfo.evmContract, amountToSponsor);
                amountToSponsor = 0;
            }
        }

        uint256 finalAmount = amount + amountToSponsor;

        HyperCoreLib.transferERC20EVMToCore(
            finalToken,
            coreTokenInfo.coreIndex,
            finalRecipient,
            finalAmount,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        emit SimpleTransferToCore(quoteNonce, finalAmount, amountToSponsor, finalRecipient, finalToken);
    }

    function _getAccountActivationFee(address token, address recipient) internal view returns (uint256) {
        bool accountActivated = HyperCoreLib.coreUserExists(recipient);

        // TODO: handle the case where the token can't be used for account activation
        return accountActivated ? 0 : coreTokenInfos[token].accountActivationFee;
    }

    function _initiateSwapFlow(
        uint256 amountLD,
        bytes32 quoteNonce,
        address initialToken,
        address finalUser,
        address finalToken,
        uint256 maxBpsToSponsor
    ) internal {
        require(address(finalTokenParams[finalToken].swapHandler) != address(0), "Final token not registered");

        CoreTokenInfo memory initialCoreTokenInfo = coreTokenInfos[initialToken];
        CoreTokenInfo memory finalCoreTokenInfo = coreTokenInfos[finalToken];
        FinalTokenParams memory finalTokenParam = finalTokenParams[finalToken];

        // Quote to ensure bridge capacity and get exact core credit for input token
        HyperCoreLib.HyperAssetAmount memory quoted = HyperCoreLib.quoteHyperCoreAmount(
            initialCoreTokenInfo.coreIndex,
            initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals,
            // TODO: this check is only for the amountLD and doesn't include sponsored amount
            HyperCoreLib.toAssetBridgeAddress(initialCoreTokenInfo.coreIndex),
            amountLD
        );
        uint64 coreAmountIn = uint64(quoted.core);

        // X1e8 = Hyperliquid price units
        uint64 spotX1e8 = HyperCoreLib.spotPx(finalTokenParam.assetIndex);
        // Directional limit price for faster fills: buy above spot, sell below spot
        uint256 adjBps = finalTokenParam.isBuy
            ? (BPS_SCALAR + finalTokenParam.suggestedSlippageBps)
            : (BPS_SCALAR - finalTokenParam.suggestedSlippageBps);
        uint64 limitPriceX1e8 = uint64((uint256(spotX1e8) * adjBps) / BPS_SCALAR);

        // Compute min expected out on Core in final token units
        // - If buying, finalToken is base: baseOut = quoteIn / price, less fee
        // - If selling, finalToken is quote: quoteOut = baseIn * price, less fee
        uint64 minOutCore;
        if (finalTokenParam.isBuy) {
            uint256 grossBaseOut = (uint256(coreAmountIn) * CORE_SCALAR) / uint256(limitPriceX1e8);
            uint256 netBaseOut = (grossBaseOut * (PPM_SCALAR - finalTokenParam.feePpm)) / PPM_SCALAR;
            minOutCore = uint64(netBaseOut);
        } else {
            uint256 grossQuoteOut = (uint256(coreAmountIn) * uint256(limitPriceX1e8)) / CORE_SCALAR;
            uint256 netQuoteOut = (grossQuoteOut * (PPM_SCALAR - finalTokenParam.feePpm)) / PPM_SCALAR;
            minOutCore = uint64(netQuoteOut);
        }

        uint64 accountCreationFee = HyperCoreLib.coreUserExists(finalUser)
            ? 0
            : uint64(finalCoreTokenInfo.accountActivationFeeCore);

        // @dev the user has no HyperCore account and we can't sponsor its creation; fall back to sending user funds on
        // HyperEVM
        if (accountCreationFee > 0 && !finalCoreTokenInfo.canBeUsedForAccountActivation) {
            sendUserFundsOnHyperEVM(quoteNonce, amountLD, finalUser, finalToken);
            return;
        }

        uint64 oneToOneSendAmount = quoted.core + accountCreationFee;
        uint64 totalCoreAmountToSponsor = oneToOneSendAmount - minOutCore;
        uint64 allowedCoreAmountToSponsor = uint64((uint256(quoted.core) * maxBpsToSponsor) / BPS_SCALAR);

        if (totalCoreAmountToSponsor > allowedCoreAmountToSponsor) {
            // TODO: here, different behavior is possible. E.g. just revert the swap part and do a simple transfer instead
            totalCoreAmountToSponsor = allowedCoreAmountToSponsor;
        }

        uint256 totalEVMAmountToSponsor = getEVMAmountToCoverCoreAmount(totalCoreAmountToSponsor);
        if (totalEVMAmountToSponsor > 0) {
            try donationBox.withdraw(IERC20(finalToken), totalEVMAmountToSponsor) {
                // success, we have totalEVMAmountToSponsor + quoted.evm on balance. Will send that to SwapHandler
            } catch {
                // TODO: a better event
                emit DonationBoxInsufficientFunds(finalToken, totalEVMAmountToSponsor);
                totalEVMAmountToSponsor = 0;
            }
        }

        // Transfer funds to SwapHandler @ core
        SwapHandler swapHandler = finalTokenParam.swapHandler;

        // 1. Fund SwapHandler @ core with `initialToken`: use it for the trade
        if (quoted.evm > 0) {
            IERC20(initialToken).safeTransfer(address(swapHandler), quoted.evm);
            swapHandler.transferFundsToSelfOnCore(
                initialToken,
                initialCoreTokenInfo.coreIndex,
                quoted.evm,
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
        if (finalTokenParam.isBuy) {
            // Buying: calculate base asset amount we're safe to set when initial token is quote asset
            uint256 pxWithFeeX1e8 = (uint256(limitPriceX1e8) * (PPM_SCALAR + finalTokenParam.feePpm)) / PPM_SCALAR;
            sizeX1e8 = uint64((uint256(coreAmountIn) * CORE_SCALAR) / pxWithFeeX1e8);
        } else {
            // Selling: sell exactly `coreAmountIn` of base asset
            sizeX1e8 = coreAmountIn;
        }

        // TODO: leave this check?
        // If computed size rounds to zero, fall back
        if (sizeX1e8 == 0) {
            sendUserFundsOnHyperEVM(quoteNonce, amountLD, finalUser, finalToken);
            return;
        }
        uint128 cloid = ++nextCloid;
        swapHandler.submitLimitOrder(finalTokenParam, limitPriceX1e8, sizeX1e8, cloid);

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
        FinalTokenParams memory finalTokenParam = finalTokenParams[finalToken];

        require(address(finalTokenParam.swapHandler) != address(0), "Final token not registered");

        uint256 head = pendingQueueHead[finalToken];
        bytes32[] storage queue = pendingQueue[finalToken];
        if (head >= queue.length || maxToProcess == 0) return;

        // Note: `availableCore` is the SwapHandler's Core balance for `finalToken`, which monotonically increases
        uint64 availableCore = HyperCoreLib.spotBalance(address(finalTokenParam.swapHandler), coreTokenInfo.coreIndex);
        uint256 processed = 0;

        while (head < queue.length && processed < maxToProcess) {
            bytes32 nonce = queue[head];

            PendingSwap storage pendingSwap = pendingSwaps[nonce];
            uint64 totalAmountToForwardToUser = pendingSwap.minCoreAmountFromLO +
                pendingSwap.sponsoredCoreAmountPreFunded;
            if (availableCore < totalAmountToForwardToUser) {
                break;
            }

            finalTokenParam.swapHandler.transferFundsToUserOnCore(
                finalTokenParam.assetIndex,
                pendingSwap.finalRecipient,
                totalAmountToForwardToUser
            );

            emit SwapFinalized(nonce, totalAmountToForwardToUser, pendingSwap.finalRecipient, pendingSwap.finalToken);

            availableCore -= totalAmountToForwardToUser;

            delete pendingSwaps[nonce];
            head += 1;
            processed += 1;
        }
    }

    function getEVMAmountToCoverCoreAmount(uint64 coreAmount) internal pure returns (uint256 evmAmount) {
        // TODO! use Taylor's function from HyperCoreLib once ready
        return coreAmount / 100;
    }

    // @dev should be used for rare cases where we can't proceed with our normal HyperCore flows: either there are
    // no funds in the spot bridge, or e.g. we can't pay for account creation for the user for some reason
    function sendUserFundsOnHyperEVM(
        bytes32 quoteNonce,
        uint256 amountLD,
        address finalUser,
        address finalToken
    ) internal {
        IERC20(finalToken).safeTransfer(finalUser, amountLD);
        emit FallbackHyperEVMFlowExecuted(quoteNonce, amountLD, 0, finalUser, finalToken);
    }
}
