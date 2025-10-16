//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { DonationBox } from "../../chain-adapters/DonationBox.sol";
import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { CoreTokenInfo } from "./Structs.sol";
import { MarketParams } from "./Structs.sol";
import { SwapHandler } from "./SwapHandler.sol";

contract HyperCoreForwarder is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant CORE_DECIMALS = 8;
    uint256 public constant BPS_DECIMALS = 4;
    uint256 public constant PPM_DECIMALS = 6;
    uint256 public constant CORE_DECIMALS_POWER = 10 ** CORE_DECIMALS;
    uint256 public constant BPS_DIVISOR = 10 ** BPS_DECIMALS;
    uint256 public constant PPM_DIVISOR = 10 ** PPM_DECIMALS;

    /// @notice A mapping of token addresses to their core token info.
    mapping(address => CoreTokenInfo) public coreTokenInfos;

    mapping(address => MarketParams) public finalTokenParams;

    /// @notice The donation box contract.
    DonationBox public immutable donationBox;

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

    modifier onlyExistingToken(address evmTokenAddress) {
        // TODO: does this work?
        require(coreTokenInfos[evmTokenAddress].tokenInfo.evmContract != address(0), "Unknown token");
        _;
    }

    constructor(address _donationBox) {
        donationBox = DonationBox(_donationBox);
    }

    function setFinalTokenParams(
        address finalToken,
        uint32 assetIndex,
        bool isBuy,
        uint32 feePpm,
        uint32 suggestedSlippageBps
    ) external onlyExistingToken(finalToken) onlyOwner {
        CoreTokenInfo storage coreTokenInfo = coreTokenInfos[finalToken];

        SwapHandler swapHandler = finalTokenParams[finalToken].swapHandler;
        if (address(swapHandler) == address(0)) {
            swapHandler = new SwapHandler();
        }

        finalTokenParams[finalToken] = MarketParams({
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
                revert("DonationBoxInsufficientFunds");
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

        uint256 maxFee = (amount * maxBpsToSponsor) / BPS_DIVISOR;
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
        MarketParams memory finalTokenParam = finalTokenParams[finalToken];

        // Quote to ensure bridge capacity and get exact core credit for input token
        HyperCoreLib.HyperAssetAmount memory quoted = HyperCoreLib.quoteHyperCoreAmount(
            initialCoreTokenInfo.coreIndex,
            initialCoreTokenInfo.tokenInfo.evmExtraWeiDecimals,
            // TODO: this check is only for the amountLD and doesn't include sponsored amount
            HyperCoreLib.toAssetBridgeAddress(initialCoreTokenInfo.coreIndex),
            amountLD
        );
        uint64 coreAmountIn = uint64(quoted.core);

        uint64 spotX1e8 = HyperCoreLib.spotPx(finalTokenParam.assetIndex);
        uint64 discountedPrice = uint64(
            (spotX1e8 * (BPS_DIVISOR - finalTokenParam.suggestedSlippageBps)) / BPS_DIVISOR
        );

        uint64 feeX1e8 = uint64(uint256(finalTokenParam.feePpm) * 10 ** (CORE_DECIMALS - PPM_DECIMALS));
        uint64 sponsorFloorX1e8 = uint64(
            CORE_DECIMALS_POWER - (maxBpsToSponsor * 10 ** (CORE_DECIMALS - BPS_DECIMALS)) + feeX1e8
        );
        uint64 limitPriceX1e8 = discountedPrice > sponsorFloorX1e8 ? discountedPrice : sponsorFloorX1e8;
        // TODO: figure out if need to convert price for isBuy = false

        // maxBpsToSponsor = 2.4
        // fee = 1.4
        // price = 1

        // 1 - 2.4 + 1.4 = 1 - 1bps
        // 100 * (1 - 1bps - 1.4bps) = 100 * (1 - 2.4bps)
        // Compute expected minimum out accounting for price and fee:
        // minOutCore = coreAmountIn * limitPrice * (1 - fee)
        uint256 minOut = (uint256(coreAmountIn) * uint256(limitPriceX1e8)) / CORE_DECIMALS_POWER;
        minOut = (minOut * (PPM_DIVISOR - finalTokenParam.feePpm)) / PPM_DIVISOR;
        uint64 minOutCore = uint64(minOut);

        // TODO: finish the rest/everthing
    }
}
