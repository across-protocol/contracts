// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

library HyperCoreLib {
    using SafeERC20 for IERC20;

    // Time-in-Force order types
    enum Tif {
        None, // invalid
        ALO, // Add Liquidity Only
        GTC, // Good-Till-Cancel
        IOC // Immediate-or-Cancel
    }

    struct HyperAssetAmount {
        uint256 evm;
        uint64 core;
        uint64 coreBalanceAssetBridge;
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold; // Unused in this implementation
        uint64 entryNtl; // Unused in this implementation
    }

    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    struct CoreUserExists {
        bool exists;
    }

    // Base asset bridge addresses
    address public constant BASE_ASSET_BRIDGE_ADDRESS = 0x2000000000000000000000000000000000000000;
    uint256 public constant BASE_ASSET_BRIDGE_ADDRESS_UINT256 = uint256(uint160(BASE_ASSET_BRIDGE_ADDRESS));

    // Precompile addresses
    address public constant SPOT_BALANCE_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000801;
    address public constant SPOT_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000808;
    address public constant CORE_USER_EXISTS_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000810;
    address constant TOKEN_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080C;
    address public constant CORE_WRITER_PRECOMPILE_ADDRESS = 0x3333333333333333333333333333333333333333;

    // CoreWriter action headers
    bytes4 public constant LIMIT_ORDER_HEADER = 0x01000001; // version=1, action=1
    bytes4 public constant SPOT_SEND_HEADER = 0x01000006; // version=1, action=6
    bytes4 public constant CANCEL_BY_CLOID_HEADER = 0x0100000B; // version=1, action=11

    // Errors
    error LimitPxIsZero();
    error OrderSizeIsZero();
    error InvalidTif();
    error SpotBalancePrecompileCallFailed();
    error CoreUserExistsPrecompileCallFailed();
    error TokenInfoPrecompileCallFailed();
    error SpotPricePrecompileCallFailed();
    error TransferAmtExceedsAssetBridgeBalance(uint256 amt, uint256 maxAmt);

    /**
     * @notice Transfer `amountEVM` from HyperEVM to `to` on HyperCore.
     * @dev Returns the amount credited on Core in Core units (post conversion).
     * @param erc20EVMAddress The address of the ERC20 token on HyperEVM
     * @param erc20CoreIndex The HyperCore index id of the token to transfer
     * @param to The address to receive tokens on HyperCore
     * @param amountEVM The amount to transfer on HyperEVM
     * @param decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @return amountCore The amount credited on Core in Core units (post conversion)
     */
    function transferERC20EVMToCore(
        address erc20EVMAddress,
        uint64 erc20CoreIndex,
        address to,
        uint256 amountEVM,
        int8 decimalDiff
    ) internal returns (uint64 amountCore) {
        // if the transfer amount exceeds the bridge balance, this wil revert
        HyperAssetAmount memory amounts = quoteHyperCoreAmount(
            erc20CoreIndex,
            decimalDiff,
            toAssetBridgeAddress(erc20CoreIndex),
            amountEVM
        );

        if (amounts.evm != 0) {
            // Transfer the tokens to this contract's address on HyperCore
            IERC20(erc20EVMAddress).safeTransfer(toAssetBridgeAddress(erc20CoreIndex), amounts.evm);

            // Transfer the tokens from this contract on HyperCore to the `to` address on HyperCore
            transferERC20CoreToCore(erc20CoreIndex, to, amounts.core);

            return amounts.core;
        }

        return 0;
    }

    /**
     * @notice Bridges `amountEVM` of `erc20` from this address on HyperEVM to this address on HyperCore.
     * @dev Returns the amount credited on Core in Core units (post conversion).
     * @dev The decimal difference is evmDecimals - coreDecimals
     * @param erc20EVMAddress The address of the ERC20 token on HyperEVM
     * @param erc20CoreIndex The HyperCore index id of the token to transfer
     * @param amountEVM The amount to transfer on HyperEVM
     * @param decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @return amountCore The amount credited on Core in Core units (post conversion)
     */
    function transferERC20EVMToSelfOnCore(
        address erc20EVMAddress,
        uint64 erc20CoreIndex,
        uint256 amountEVM,
        int8 decimalDiff
    ) internal returns (uint64 amountCore) {
        // if the transfer amount exceeds the bridge balance, this wil revert
        HyperAssetAmount memory amounts = quoteHyperCoreAmount(
            erc20CoreIndex,
            decimalDiff,
            toAssetBridgeAddress(erc20CoreIndex),
            amountEVM
        );

        if (amounts.evm != 0) {
            // Transfer the tokens to this contract's address on HyperCore
            IERC20(erc20EVMAddress).safeTransfer(toAssetBridgeAddress(erc20CoreIndex), amounts.evm);

            return amounts.core;
        }

        return 0;
    }

    /**
     * @notice Transfers tokens from this contract on HyperCore to the `to` address on HyperCore
     * @param erc20CoreIndex The HyperCore index id of the token
     * @param to The address to receive tokens on HyperCore
     * @param amountCore The amount to transfer on HyperCore
     */
    function transferERC20CoreToCore(uint64 erc20CoreIndex, address to, uint64 amountCore) internal {
        bytes memory action = abi.encode(to, erc20CoreIndex, amountCore);
        bytes memory payload = abi.encodePacked(SPOT_SEND_HEADER, action);

        ICoreWriter(CORE_WRITER_PRECOMPILE_ADDRESS).sendRawAction(payload);
    }

    /**
     * @notice Submit a limit order on HyperCore.
     * @dev Expects price & size already scaled by 1e8 per HyperCore spec.
     * @param asset The asset index of the order
     * @param isBuy Whether the order is a buy order
     * @param limitPriceX1e8 The limit price of the order scaled by 1e8
     * @param sizeX1e8 The size of the order scaled by 1e8
     * @param reduceOnly If true, only reduce existing position rather than opening a new opposing order
     * @param tif Time-in-Force: ALO, GTC, IOC (None invalid)
     * @param cloid The client order id of the order, 0 means no cloid
     */
    function submitLimitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPriceX1e8,
        uint64 sizeX1e8,
        bool reduceOnly,
        Tif tif,
        uint128 cloid
    ) internal {
        // Basic sanity checks
        if (limitPriceX1e8 == 0) revert LimitPxIsZero();
        if (sizeX1e8 == 0) revert OrderSizeIsZero();
        if (tif == Tif.None || uint8(tif) > uint8(type(Tif).max)) revert InvalidTif();

        // Encode the action
        bytes memory encodedAction = abi.encode(asset, isBuy, limitPriceX1e8, sizeX1e8, reduceOnly, uint8(tif), cloid);

        // Prefix with the limit-order header
        bytes memory data = abi.encodePacked(LIMIT_ORDER_HEADER, encodedAction);

        // Enqueue limit order to HyperCore via CoreWriter precompile
        ICoreWriter(CORE_WRITER_PRECOMPILE_ADDRESS).sendRawAction(data);
    }

    /**
     * @notice Enqueue a cancel-order-by-CLOID for a given asset.
     * @param asset The asset index of the order
     * @param cloid The client order id of the order
     */
    function cancelOrderByCloid(uint32 asset, uint128 cloid) internal {
        // Encode the action
        bytes memory encodedAction = abi.encode(asset, cloid);

        // Prefix with the cancel-by-cloid header
        bytes memory data = abi.encodePacked(CANCEL_BY_CLOID_HEADER, encodedAction);

        // Enqueue cancel order by CLOID to HyperCore via CoreWriter precompile
        ICoreWriter(CORE_WRITER_PRECOMPILE_ADDRESS).sendRawAction(data);
    }

    /**
     * @notice Get the balance of the specified ERC20 for `account` on HyperCore.
     * @param account The address of the account to get the balance of
     * @param token The token to get the balance of
     * @return balance The balance of the specified ERC20 for `account` on HyperCore
     */
    function spotBalance(address account, uint64 token) internal view returns (uint64 balance) {
        (bool success, bytes memory result) = SPOT_BALANCE_PRECOMPILE_ADDRESS.staticcall(abi.encode(account, token));
        if (!success) revert SpotBalancePrecompileCallFailed();
        SpotBalance memory _spotBalance = abi.decode(result, (SpotBalance));
        return _spotBalance.total;
    }

    /**
     * @notice Checks if the user exists / has been activated on HyperCore.
     * @param user The address of the user to check if they exist on HyperCore
     * @return exists True if the user exists on HyperCore, false otherwise
     */
    function coreUserExists(address user) internal view returns (bool) {
        (bool success, bytes memory result) = CORE_USER_EXISTS_PRECOMPILE_ADDRESS.staticcall(abi.encode(user));
        if (!success) revert CoreUserExistsPrecompileCallFailed();
        CoreUserExists memory _coreUserExists = abi.decode(result, (CoreUserExists));
        return _coreUserExists.exists;
    }

    /**
     * @notice Get the info of the specified token on HyperCore.
     * @param erc20CoreIndex The token to get the info of
     * @return tokenInfo The info of the specified token on HyperCore
     */
    function tokenInfo(uint32 erc20CoreIndex) internal view returns (TokenInfo memory) {
        (bool success, bytes memory result) = TOKEN_INFO_PRECOMPILE_ADDRESS.staticcall(abi.encode(erc20CoreIndex));
        if (!success) revert TokenInfoPrecompileCallFailed();
        TokenInfo memory _tokenInfo = abi.decode(result, (TokenInfo));
        return _tokenInfo;
    }

    /**
     * @notice Get the current spot price for a given market asset index, scaled by 1e8.
     */
    function spotPx(uint32 assetIndex) internal view returns (uint64) {
        (bool success, bytes memory result) = SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(assetIndex));
        if (!success) revert SpotPricePrecompileCallFailed();
        return abi.decode(result, (uint64));
    }

    /**
     * @notice Quotes the conversion of evm tokens to hypercore tokens
     * @param erc20CoreIndex The HyperCore index id of the token to transfer
     * @param decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @param bridgeAddress The asset bridge address of the token to transfer
     * @param amountEVM The number of tokens that (pre-dusted) that we are trying to send
     * @return HyperAssetAmount The amount of tokens to send to HyperCore (scaled on evm),
     * dust (to be refunded), and the swap amount (of the tokens scaled on hypercore)
     */
    function quoteHyperCoreAmount(
        uint64 erc20CoreIndex,
        int8 decimalDiff,
        address bridgeAddress,
        uint256 amountEVM
    ) internal view returns (HyperAssetAmount memory) {
        return toHyperAssetAmount(amountEVM, spotBalance(bridgeAddress, erc20CoreIndex), decimalDiff);
    }

    /**
     * @notice Converts a core index id to an asset bridge address
     * @param erc20CoreIndex The core token index id to convert
     * @return assetBridgeAddress The asset bridge address
     */
    function toAssetBridgeAddress(uint64 erc20CoreIndex) internal pure returns (address) {
        return address(uint160(BASE_ASSET_BRIDGE_ADDRESS_UINT256 + erc20CoreIndex));
    }

    /**
     * @notice Converts an asset bridge address to a core index id
     * @param assetBridgeAddress The asset bridge address to convert
     * @return erc20CoreIndex The core token index id
     */
    function toTokenId(address assetBridgeAddress) internal pure returns (uint64) {
        return uint64(uint160(assetBridgeAddress) - BASE_ASSET_BRIDGE_ADDRESS_UINT256);
    }

    /**
     * @notice Converts an amount and an asset to a evm amount and core amount
     * @param amountEVMPreDusted The amount to convert
     * @param assetBridgeSupplyCore The maximum amount transferable capped by the number of tokens located on the HyperCore's side of the asset bridge
     * @param decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @return HyperAssetAmount The evm amount and core amount
     */
    function toHyperAssetAmount(
        uint256 amountEVMPreDusted,
        uint64 assetBridgeSupplyCore,
        int8 decimalDiff
    ) internal pure returns (HyperAssetAmount memory) {
        uint256 amountEVM;
        uint64 amountCore;

        /// @dev HyperLiquid decimal conversion: Scale EVM (u256,evmDecimals) -> Core (u64,coreDecimals)
        /// @dev Core amount is guaranteed to be within u64 range.
        if (decimalDiff > 0) {
            (amountEVM, amountCore) = toHyperAssetAmountDecimalDifferenceGtZero(
                amountEVMPreDusted,
                assetBridgeSupplyCore,
                uint8(decimalDiff)
            );
        } else {
            (amountEVM, amountCore) = toHyperAssetAmountDecimalDifferenceLeqZero(
                amountEVMPreDusted,
                assetBridgeSupplyCore,
                uint8(-1 * decimalDiff)
            );
        }

        return HyperAssetAmount({ evm: amountEVM, core: amountCore, coreBalanceAssetBridge: assetBridgeSupplyCore });
    }

    /**
     * @notice Computes hyperAssetAmount when EVM decimals > Core decimals
     * @notice Reverts if the transfers amount exceeds the asset bridge balance
     * @param amountEVMPreDusted The amount to convert
     * @param maxTransferableAmountCore The maximum transferrable amount capped by the asset bridge has range [0,u64.max]
     * @param decimalDiff The decimal difference between HyperEVM and HyperCore
     * @return amountEVM The EVM amount
     * @return amountCore The core amount
     */
    function toHyperAssetAmountDecimalDifferenceGtZero(
        uint256 amountEVMPreDusted,
        uint64 maxTransferableAmountCore,
        uint8 decimalDiff
    ) internal pure returns (uint256 amountEVM, uint64 amountCore) {
        uint256 scale = 10 ** decimalDiff;
        uint256 maxTransferableAmountEVM = maxTransferableAmountCore * scale;

        unchecked {
            /// @dev Strip out dust from _amount so that _amount and maxEvmAmountFromCoreMax have a maximum of _decimalDiff starting 0s
            amountEVM = amountEVMPreDusted - (amountEVMPreDusted % scale); // Safe: dustAmount = amountEVMPreDusted % scale, so dust <= amountEVMPreDusted

            if (amountEVM > maxTransferableAmountEVM)
                revert TransferAmtExceedsAssetBridgeBalance(amountEVM, maxTransferableAmountEVM);

            /// @dev Safe: Guaranteed to be in the range of [0, u64.max] because it is upperbounded by uint64 maxAmt
            amountCore = uint64(amountEVM / scale);
        }
    }

    /**
     * @notice Computes hyperAssetAmount when EVM decimals < Core decimals and 0
     * @notice Reverts if the transfers amount exceeds the asset bridge balance
     * @param amountEVMPreDusted The amount to convert
     * @param maxTransferableAmountCore The maximum transferrable amount capped by the asset bridge
     * @param decimalDiff The decimal difference between HyperEVM and HyperCore
     * @return amountEVM The EVM amount
     * @return amountCore The core amount
     */
    function toHyperAssetAmountDecimalDifferenceLeqZero(
        uint256 amountEVMPreDusted,
        uint64 maxTransferableAmountCore,
        uint8 decimalDiff
    ) internal pure returns (uint256 amountEVM, uint64 amountCore) {
        uint256 scale = 10 ** decimalDiff;
        uint256 maxTransferableAmountEVM = maxTransferableAmountCore / scale;

        unchecked {
            amountEVM = amountEVMPreDusted;

            /// @dev When `Core > EVM` there will be no opening dust to strip out since all tokens in evm can be represented on core
            /// @dev Safe: Bound amountEvm to the range of [0, evmscaled u64.max]
            if (amountEVMPreDusted > maxTransferableAmountEVM)
                revert TransferAmtExceedsAssetBridgeBalance(amountEVM, maxTransferableAmountEVM);

            /// @dev Safe: Guaranteed to be in the range of [0, u64.max] because it is upperbounded by uint64 maxAmt
            amountCore = uint64(amountEVM * scale);
        }
    }

    // -------------------------
    // Pure conversion utilities
    // -------------------------

    /**
     * @notice Convert an EVM-denominated amount to Core units without consulting bridge balances.
     * @dev decimalDiff = evmDecimals - coreDecimals. Floors when EVM has more decimals than Core.
     */
    function convertEvmToCoreNoBridge(uint256 amountEvm, int8 decimalDiff) internal pure returns (uint64 amountCore) {
        if (amountEvm == 0) return 0;
        if (decimalDiff > 0) {
            uint256 scale = 10 ** uint8(uint8(decimalDiff));
            return uint64(amountEvm / scale);
        } else if (decimalDiff < 0) {
            uint256 scale = 10 ** uint8(uint8(-decimalDiff));
            uint256 v = amountEvm * scale;
            return uint64(v);
        } else {
            return uint64(amountEvm);
        }
    }

    /**
     * @notice Convert a Core-denominated amount to EVM units, rounding up when needed so that
     *         convertEvmToCoreNoBridge(result, decimalDiff) >= amountCore.
     */
    function convertCoreToEvmCeil(uint64 amountCore, int8 decimalDiff) internal pure returns (uint256 amountEvm) {
        if (amountCore == 0) return 0;
        if (decimalDiff > 0) {
            uint256 scale = 10 ** uint8(uint8(decimalDiff));
            return uint256(amountCore) * scale;
        } else if (decimalDiff < 0) {
            uint256 scale = 10 ** uint8(uint8(-decimalDiff));
            return _ceilDiv(amountCore, scale);
        } else {
            return uint256(amountCore);
        }
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
