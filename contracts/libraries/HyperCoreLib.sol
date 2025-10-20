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
    // TODO: maybe we should be using https://github.com/hyperliquid-dev/hyper-evm-lib instead?
    address public constant SPOT_BALANCE_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000801;
    address public constant SPOT_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000808;
    address public constant CORE_USER_EXISTS_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000810;
    address public constant TOKEN_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080C;
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
    error SpotPxPrecompileCallFailed();
    error TransferAmtExceedsAssetBridgeBalance(uint256 amt, uint256 maxAmt);

    /**
     * @notice Transfer `amountEVM` from HyperEVM to `to` on HyperCore.
     * @dev Returns the amount credited on Core in Core units (post conversion).
     * @param erc20EVMAddress The address of the ERC20 token on HyperEVM
     * @param erc20CoreIndex The HyperCore index id of the token to transfer
     * @param to The address to receive tokens on HyperCore
     * @param amountEVM The amount to transfer on HyperEVM
     * @param decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @return amountEVMSent The amount sent on HyperEVM
     * @return amountCoreToReceive The amount credited on Core in Core units (post conversion)
     */
    function transferERC20EVMToCore(
        address erc20EVMAddress,
        uint64 erc20CoreIndex,
        address to,
        uint256 amountEVM,
        int8 decimalDiff
    ) internal returns (uint256 amountEVMSent, uint64 amountCoreToReceive) {
        // if the transfer amount exceeds the bridge balance, this wil revert
        (uint256 _amountEVMToSend, uint64 _amountCoreToReceive) = maximumEVMSendAmountToAmounts(amountEVM, decimalDiff);

        if (_amountEVMToSend != 0) {
            // Transfer the tokens to this contract's address on HyperCore
            IERC20(erc20EVMAddress).safeTransfer(toAssetBridgeAddress(erc20CoreIndex), _amountEVMToSend);

            // Transfer the tokens from this contract on HyperCore to the `to` address on HyperCore
            transferERC20CoreToCore(erc20CoreIndex, to, _amountCoreToReceive);
        }

        return (_amountEVMToSend, _amountCoreToReceive);
    }

    /**
     * @notice Bridges `amountEVM` of `erc20` from this address on HyperEVM to this address on HyperCore.
     * @dev Returns the amount credited on Core in Core units (post conversion).
     * @dev The decimal difference is evmDecimals - coreDecimals
     * @param erc20EVMAddress The address of the ERC20 token on HyperEVM
     * @param erc20CoreIndex The HyperCore index id of the token to transfer
     * @param amountEVM The amount to transfer on HyperEVM
     * @param decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @return amountEVMSent The amount sent on HyperEVM
     * @return amountCoreToReceive The amount credited on Core in Core units (post conversion)
     */
    function transferERC20EVMToSelfOnCore(
        address erc20EVMAddress,
        uint64 erc20CoreIndex,
        uint256 amountEVM,
        int8 decimalDiff
    ) internal returns (uint256 amountEVMSent, uint64 amountCoreToReceive) {
        (uint256 _amountEVMToSend, uint64 _amountCoreToReceive) = maximumEVMSendAmountToAmounts(amountEVM, decimalDiff);

        if (_amountEVMToSend != 0) {
            // Transfer the tokens to this contract's address on HyperCore
            IERC20(erc20EVMAddress).safeTransfer(toAssetBridgeAddress(erc20CoreIndex), _amountEVMToSend);
        }

        return (_amountEVMToSend, _amountCoreToReceive);
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
     * @notice Get the spot price of the specified asset on HyperCore.
     * @param index The asset index to get the spot price of
     * @return spotPx The spot price of the specified asset on HyperCore scaled by 1e8
     */
    function spotPx(uint32 index) internal view returns (uint64) {
        (bool success, bytes memory result) = SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(index));
        if (!success) revert SpotPxPrecompileCallFailed();
        return abi.decode(result, (uint64));
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
     * @notice Checks if an amount is safe to bridge from HyperEVM to HyperCore
     * @dev Verifies that the asset bridge has sufficient balance to cover the amount plus a buffer
     * @param erc20CoreIndex The HyperCore index id of the token
     * @param coreAmount The amount that the bridging should result in on HyperCore
     * @param coreBufferAmount The minimum buffer amount that should remain on HyperCore after bridging
     * @return True if the bridge has enough balance to safely bridge the amount, false otherwise
     */
    function isCoreAmountSafeToBridge(
        uint64 erc20CoreIndex,
        uint64 coreAmount,
        uint64 coreBufferAmount
    ) internal view returns (bool) {
        address bridgeAddress = toAssetBridgeAddress(erc20CoreIndex);
        uint64 currentBridgeBalance = spotBalance(bridgeAddress, erc20CoreIndex);

        // Return true if currentBridgeBalance >= coreAmount + coreBufferAmount
        return currentBridgeBalance >= coreAmount + coreBufferAmount;
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
     * @notice Returns an amount to send on HyperEVM to receive AT LEAST the minimumCoreReceiveAmount on HyperCore
     * @param minimumCoreReceiveAmount The minimum amount desired to receive on HyperCore
     * @param decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @return amountEVMToSend The amount to send on HyperEVM to receive at least minimumCoreReceiveAmount on HyperCore
     * @return amountCoreToReceive The amount that will be received on core if the amountEVMToSend is sent from HyperEVM
     */
    function minimumCoreReceiveAmountToAmounts(
        uint64 minimumCoreReceiveAmount,
        int8 decimalDiff
    ) internal pure returns (uint256 amountEVMToSend, uint64 amountCoreToReceive) {
        if (decimalDiff == 0) {
            // Same decimals between HyperEVM and HyperCore
            amountEVMToSend = uint256(minimumCoreReceiveAmount);
            amountCoreToReceive = minimumCoreReceiveAmount;
        } else if (decimalDiff > 0) {
            // EVM token has more decimals than Core
            // Scale up to represent the same value in higher-precision EVM units
            amountEVMToSend = uint256(minimumCoreReceiveAmount) * (10 ** uint8(decimalDiff));
            amountCoreToReceive = minimumCoreReceiveAmount;
        } else {
            // Core token has more decimals than EVM
            // Scale down, rounding UP to avoid shortfall on Core
            uint256 scaleDivisor = 10 ** uint8(-decimalDiff);
            amountEVMToSend = (uint256(minimumCoreReceiveAmount) + scaleDivisor - 1) / scaleDivisor; // ceil division
            amountCoreToReceive = uint64(amountEVMToSend * scaleDivisor);
        }
    }

    /**
     * @notice Converts a maximum EVM amount to send into an EVM amount to send to avoid loss to dust,
     * @notice and the corresponding amount that will be recieved on Core.
     * @param maximumEVMSendAmount The maximum amount to send on HyperEVM
     * @param decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @return amountEVMToSend The amount to send on HyperEVM
     * @return amountCoreToReceive The amount that will be received on HyperCore if the amountEVMToSend is sent
     */
    function maximumEVMSendAmountToAmounts(
        uint256 maximumEVMSendAmount,
        int8 decimalDiff
    ) internal pure returns (uint256 amountEVMToSend, uint64 amountCoreToReceive) {
        /// @dev HyperLiquid decimal conversion: Scale EVM (u256,evmDecimals) -> Core (u64,coreDecimals)
        /// @dev Core amount is guaranteed to be within u64 range.
        if (decimalDiff == 0) {
            amountEVMToSend = maximumEVMSendAmount;
            amountCoreToReceive = uint64(amountEVMToSend);
        } else if (decimalDiff > 0) {
            // EVM token has more decimals than Core
            uint256 scale = 10 ** uint8(decimalDiff);
            amountEVMToSend = maximumEVMSendAmount - (maximumEVMSendAmount % scale); // Safe: dustAmount = maximumEVMSendAmount % scale, so dust <= maximumEVMSendAmount

            /// @dev Safe: Guaranteed to be in the range of [0, u64.max] because it is upperbounded by uint64 maxAmt
            amountCoreToReceive = uint64(amountEVMToSend / scale);
        } else {
            // Core token has more decimals than EVM
            uint256 scale = 10 ** uint8(-1 * decimalDiff);
            amountEVMToSend = maximumEVMSendAmount;

            /// @dev Safe: Guaranteed to be in the range of [0, u64.max] because it is upperbounded by uint64 maxAmt
            amountCoreToReceive = uint64(amountEVMToSend * scale);
        }
    }

    function convertCoreDecimalsSimple(
        uint64 amountDecimalsFrom,
        uint8 decimalsFrom,
        uint8 decimalsTo
    ) internal pure returns (uint64) {
        if (decimalsFrom == decimalsTo) {
            return amountDecimalsFrom;
        } else if (decimalsFrom < decimalsTo) {
            return uint64(amountDecimalsFrom * 10 ** (decimalsTo - decimalsFrom));
        } else {
            // round down
            return uint64(amountDecimalsFrom / 10 ** (decimalsFrom - decimalsTo));
        }
    }
}
