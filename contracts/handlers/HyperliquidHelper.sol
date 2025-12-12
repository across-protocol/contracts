// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-v4/security/ReentrancyGuard.sol";
import { HyperCoreLib } from "../libraries/HyperCoreLib.sol";
import { Ownable } from "@openzeppelin/contracts-v4/access/Ownable.sol";

interface CCTP_CORE_DEPOSIT_WALLET {
    function deposit(uint256 amount, uint32 destinationDex) external;
}
/**
 * @notice Contract deployed on HyperEVM designed to help the deployer deposit and withdraw tokens to and from Hypercore,
 * and place orders atomically.
 */
contract HyperliquidHelper is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    struct TokenInfo {
        // HyperEVM token address.
        address evmAddress;
        // Hypercore system address used as recipient to withdraw from Core to EVM.
        address hypercoreSystemAddress;
        // Hypercore token index.
        uint64 tokenId;
        // coreDecimals - evmDecimals. e.g. -2 for USDH.
        int8 decimalDiff;
    }

    struct Call {
        address target;
        bytes callData;
        uint256 value;
    }

    // Stores hardcoded Hypercore configurations for tokens that this handler supports.
    mapping(address => TokenInfo) public supportedTokens;

    address public immutable USDC_ADDRESS;
    address public immutable CCTP_CORE_DEPOSIT_WALLET_ADDRESS;

    error TokenNotSupported();
    error CallReverted(uint256 index, Call[] calls);
    error InvalidCall(uint256 index, Call[] calls);

    event AddedSupportedToken(address evmAddress, address hypercoreSystemAddress, uint64 tokenId, int8 decimalDiff);

    constructor(address usdcAddress, address cctpCoreDepositWalletAddress) {
        USDC_ADDRESS = usdcAddress;
        CCTP_CORE_DEPOSIT_WALLET_ADDRESS = cctpCoreDepositWalletAddress;
    }
    /// -------------------------------------------------------------------------------------------------------------
    /// - ONLY OWNER FUNCTIONS -
    /// -------------------------------------------------------------------------------------------------------------

    function depositToHypercore(
        address token,
        uint32 spotMarketIndex,
        bool isBuy,
        uint256 amount,
        uint64 limitPriceX1e8,
        uint128 cloid,
        HyperCoreLib.Tif tif
    ) external nonReentrant onlyOwner {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint64 amountCoreToReceive = _depositToHypercore(token, amount);
        _placeOrder(spotMarketIndex, isBuy, limitPriceX1e8, amountCoreToReceive, cloid, tif);
    }

    function withdrawToHyperevm(address token, uint64 coreAmount) external nonReentrant onlyOwner {
        _withdrawToHyperevm(token, coreAmount);
    }

    function attemptCalls(Call[] memory calls) external onlyOwner {
        uint256 length = calls.length;
        for (uint256 i = 0; i < length; ++i) {
            Call memory call = calls[i];

            // If we are calling an EOA with calldata, assume target was incorrectly specified and revert.
            if (call.callData.length > 0 && call.target.code.length == 0) {
                revert InvalidCall(i, calls);
            }

            (bool success, ) = call.target.call{ value: call.value }(call.callData);
            if (!success) revert CallReverted(i, calls);
        }
    }

    /**
     * @notice Adds a new token to the supported tokens list.
     * @dev Caller must be owner of this contract.
     * @param evmAddress The address of the EVM token.
     * @param tokenId The index of the Hypercore token.
     * @param decimalDiff The difference in decimals between the EVM and Hypercore tokens.
     */
    function addSupportedToken(
        address evmAddress,
        address hypercoreSystemAddress,
        uint64 tokenId,
        int8 decimalDiff
    ) external onlyOwner {
        supportedTokens[evmAddress] = TokenInfo({
            evmAddress: evmAddress,
            hypercoreSystemAddress: hypercoreSystemAddress,
            tokenId: tokenId,
            decimalDiff: decimalDiff
        });
        emit AddedSupportedToken(evmAddress, hypercoreSystemAddress, tokenId, decimalDiff);
    }

    /**
     * @notice Send Hypercore funds to a user from this contract's Hypercore account
     * @dev The coreAmount parameter is specified in Hypercore units which often differs from the EVM units for the
     * same token.
     * @param token The token address
     * @param coreAmount The amount of tokens on Hypercore to sweep
     * @param user The address of the user to send the tokens to
     */
    function sweepCoreFundsToUser(address token, uint64 coreAmount, address user) external onlyOwner nonReentrant {
        uint64 tokenIndex = _getTokenInfo(token).tokenId;
        HyperCoreLib.transferERC20CoreToCore(tokenIndex, user, coreAmount);
    }

    /**
     * @notice Send ERC20 tokens to a user from this contract's address on HyperEVM
     * @param token The token address
     * @param evmAmount The amount of tokens to sweep
     * @param user The address of the user to send the tokens to
     */
    function sweepERC20ToUser(address token, uint256 evmAmount, address user) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(user, evmAmount);
    }

    function cancelOrderByCloid(uint32 spotMarketIndex, uint128 cloid) external onlyOwner nonReentrant {
        HyperCoreLib.cancelOrderByCloid(spotMarketIndex, cloid);
    }

    /// -------------------------------------------------------------------------------------------------------------
    /// - INTERNAL FUNCTIONS -
    /// -------------------------------------------------------------------------------------------------------------

    function _depositToHypercore(address token, uint256 evmAmount) internal returns (uint64 amountCoreToReceive) {
        if (token == USDC_ADDRESS) {
            IERC20(USDC_ADDRESS).forceApprove(CCTP_CORE_DEPOSIT_WALLET_ADDRESS, evmAmount);
            CCTP_CORE_DEPOSIT_WALLET(CCTP_CORE_DEPOSIT_WALLET_ADDRESS).deposit(evmAmount, type(uint32).max); // Deposit into spot account
        } else {
            TokenInfo memory tokenInfo = _getTokenInfo(token);
            uint64 tokenIndex = tokenInfo.tokenId;
            int8 decimalDiff = tokenInfo.decimalDiff;

            // We assume this account is already activated.

            (, amountCoreToReceive) = HyperCoreLib.transferERC20EVMToCore(
                token,
                tokenIndex,
                address(this),
                evmAmount,
                decimalDiff
            );
        }
    }

    function _placeOrder(
        uint32 spotMarketIndex,
        bool isBuy,
        uint64 limitPriceX1e8,
        uint64 sizeX1e8,
        uint128 cloid,
        HyperCoreLib.Tif tif
    ) internal {
        HyperCoreLib.submitLimitOrder(
            spotMarketIndex,
            isBuy,
            limitPriceX1e8,
            sizeX1e8,
            false /* reduceOnly */,
            tif,
            cloid
        );
    }

    function _withdrawToHyperevm(address token, uint64 coreAmount) internal {
        TokenInfo memory tokenInfo = _getTokenInfo(token);
        uint64 tokenIndex = tokenInfo.tokenId;
        address hypercoreSystemAddress = tokenInfo.hypercoreSystemAddress;
        // To withdraw to EVM, spot send tokens to the HyperEVM token address on Core.
        HyperCoreLib.transferERC20CoreToCore(tokenIndex, hypercoreSystemAddress, coreAmount);
    }

    function _getTokenInfo(address evmAddress) internal view returns (TokenInfo memory) {
        if (supportedTokens[evmAddress].evmAddress == address(0)) {
            revert TokenNotSupported();
        }
        return supportedTokens[evmAddress];
    }

    // Native tokens are not supported by this contract, so there is no fallback function.
}
