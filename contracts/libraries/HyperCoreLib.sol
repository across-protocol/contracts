// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// TODO: handle MIT / BUSL license
// Note:
// This library does not check if token recipient is activated on HyperCore

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

library HyperCoreLib {
    using SafeERC20 for IERC20;

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

    struct CoreUserExists {
        bool exists;
    }

    // Precompile addresses
    address public constant SPOT_BALANCE_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000801;
    address public constant CORE_USER_EXISTS_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000810;
    address public constant CORE_WRITER_PRECOMPILE_ADDRESS = 0x3333333333333333333333333333333333333333;

    // CoreWriter action headers
    bytes4 public constant LIMIT_ORDER_HEADER = 0x01000001; // version=1, action=1
    bytes4 public constant SPOT_SEND_HEADER = 0x01000006; // version=1, action=6
    bytes4 public constant CANCEL_BY_CLOID_HEADER = 0x0100000B; // version=1, action=11

    // Base asset bridge addresses
    address public constant BASE_ASSET_BRIDGE_ADDRESS = 0x2000000000000000000000000000000000000000;
    uint256 public constant BASE_ASSET_BRIDGE_ADDRESS_UINT256 = uint256(uint160(BASE_ASSET_BRIDGE_ADDRESS));

    error TransferAmtExceedsAssetBridgeBalance(uint256 amt, uint256 maxAmt);
    error SpotBalancePrecompileCallFailed();
    error CoreUserExistsPrecompileCallFailed();
    error LimitPxIsZero();
    error OrderSizeIsZero();
    error InvalidTif();

    /**
     * @notice Transfer `amountEVMDecimals` of `erc20` from HyperEVM to `toHCAccount` on HyperCore.
     * @dev Returns the amount credited on Core in Core units (post conversion).
     */
    function transferERC20ToHyperCore(
        address erc20,
        uint256 amountEVMDecimals,
        address to,
        uint64 erc20HCIndex,
        int8 decimalDiff
    ) internal returns (uint64 coreAmount) {
        // if the transfer amount exceeds the bridge balance, this wil revert
        HyperAssetAmount memory amounts = quoteHyperCoreAmount(
            erc20HCIndex,
            decimalDiff,
            into_assetBridgeAddress(erc20HCIndex),
            amountEVMDecimals
        );

        if (amounts.evm != 0) {
            // Transfer the tokens to this contract's address on HyperCore
            IERC20(erc20).safeTransfer(into_assetBridgeAddress(erc20HCIndex), amounts.evm);

            // Transfer the tokens from this contract on HyperCore to the `to` address on HyperCore
            transferERC20OnHyperCore(erc20HCIndex, to, amounts.core);

            return amounts.core;
        }

        return 0;
    }

    /**
     * @notice Transfers tokens from this contract on HyperCore to
     * @notice the `to` address on HyperCore using the CoreWriter precompile
     * @param erc20CoreIndex The core index of the token
     * @param to The address to receive tokens on HyperCore
     * @param coreAmount The amount to transfer on HyperCore
     */
    function transferERC20OnHyperCore(uint64 erc20CoreIndex, address to, uint64 coreAmount) internal {
        bytes memory action = abi.encode(to, erc20CoreIndex, coreAmount);
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
     * @param encodedTif Time-in-Force: 1 = ALO, 2 = GTC, 3 = IOC
     * @param cloid The client order id of the order, 0 means no cloid
     */
    function submitLimitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPriceX1e8,
        uint64 sizeX1e8,
        bool reduceOnly,
        uint8 encodedTif,
        uint128 cloid
    ) internal {
        // Basic sanity checks
        if (limitPriceX1e8 == 0) revert LimitPxIsZero();
        if (sizeX1e8 == 0) revert OrderSizeIsZero();
        if (!(encodedTif == 1 || encodedTif == 2 || encodedTif == 3)) revert InvalidTif();

        // Encode the action payload
        bytes memory action = abi.encode(asset, isBuy, limitPriceX1e8, sizeX1e8, reduceOnly, encodedTif, cloid);

        // Prefix with the limit-order header
        bytes memory payload = abi.encodePacked(LIMIT_ORDER_HEADER, action);

        // Enqueue limit order to HyperCore via CoreWriter precompile
        ICoreWriter(CORE_WRITER_PRECOMPILE_ADDRESS).sendRawAction(payload);
    }

    /**
     * @notice Enqueue a cancel-order-by-CLOID for a given asset.
     */
    function cancelOrderByCloid(uint32 asset, uint128 cloid) internal {
        bytes memory body = abi.encode(asset, cloid);

        // Prefix with the cancel-by-cloid header
        bytes memory data = abi.encodePacked(CANCEL_BY_CLOID_HEADER, body);

        // Enqueue cancel order by CLOID to HyperCore via CoreWriter precompile
        ICoreWriter(CORE_WRITER_PRECOMPILE_ADDRESS).sendRawAction(data);
    }

    /**
     * @notice Quotes the conversion of evm tokens to hypercore tokens
     * @param _coreIndexId The core index id of the token to transfer
     * @param _decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @param _bridgeAddress The asset bridge address of the token to transfer
     * @param _amountLD The number of tokens that (pre-dusted) that we are trying to send
     * @return HyperAssetAmount - The amount of tokens to send to HyperCore (scaled on evm), dust (to be refunded), and the swap amount (of the tokens scaled on hypercore)
     */
    function quoteHyperCoreAmount(
        uint64 _coreIndexId,
        int8 _decimalDiff,
        address _bridgeAddress,
        uint256 _amountLD
    ) internal view returns (HyperAssetAmount memory) {
        return into_hyperAssetAmount(_amountLD, spotBalance(_bridgeAddress, _coreIndexId), _decimalDiff);
    }

    /**
     * @notice Get the balance of the specified ERC20 for `account` on HyperCore.
     */
    function spotBalance(address account, uint64 token) internal view returns (uint64 balance) {
        (bool success, bytes memory result) = SPOT_BALANCE_PRECOMPILE_ADDRESS.staticcall(abi.encode(account, token));
        if (!success) revert SpotBalancePrecompileCallFailed();
        SpotBalance memory _spotBalance = abi.decode(result, (SpotBalance));
        return _spotBalance.total;
    }

    /**
     * @notice Checks if the user exists / has been activated on HyperCore.
     */
    function coreUserExists(address user) internal view returns (bool) {
        (bool success, bytes memory result) = CORE_USER_EXISTS_PRECOMPILE_ADDRESS.staticcall(abi.encode(user));
        if (!success) revert CoreUserExistsPrecompileCallFailed();
        CoreUserExists memory _coreUserExists = abi.decode(result, (CoreUserExists));
        return _coreUserExists.exists;
    }

    /**
     * @notice Converts a core index id to an asset bridge address
     * @param _coreIndexId The core index id to convert
     * @return _assetBridgeAddress The asset bridge address
     */
    function into_assetBridgeAddress(uint64 _coreIndexId) internal pure returns (address) {
        return address(uint160(BASE_ASSET_BRIDGE_ADDRESS_UINT256 + _coreIndexId));
    }

    /**
     * @notice Converts an asset bridge address to a core index id
     * @param _assetBridgeAddress The asset bridge address to convert
     * @return _coreIndexId The core index id
     */
    function into_tokenId(address _assetBridgeAddress) internal pure returns (uint64) {
        return uint64(uint160(_assetBridgeAddress) - BASE_ASSET_BRIDGE_ADDRESS_UINT256);
    }

    /**
     * @notice Converts an amount and an asset to a evm amount and core amount
     * @param _amount The amount to convert
     * @param _assetBridgeSupply The maximum amount transferable capped by the number of tokens located on the HyperCore's side of the asset bridge
     * @param _decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @return HyperAssetAmount memory - The evm amount and core amount
     */
    function into_hyperAssetAmount(
        uint256 _amount,
        uint64 _assetBridgeSupply,
        int8 _decimalDiff
    ) internal pure returns (HyperAssetAmount memory) {
        uint256 amountEVM;
        uint64 amountCore;

        /// @dev HyperLiquid decimal conversion: Scale EVM (u256,evmDecimals) -> Core (u64,coreDecimals)
        /// @dev Core amount is guaranteed to be within u64 range.
        if (_decimalDiff > 0) {
            (amountEVM, amountCore) = into_hyperAssetAmount_decimal_difference_gt_zero(
                _amount,
                _assetBridgeSupply,
                uint8(_decimalDiff)
            );
        } else {
            (amountEVM, amountCore) = into_hyperAssetAmount_decimal_difference_leq_zero(
                _amount,
                _assetBridgeSupply,
                uint8(-1 * _decimalDiff)
            );
        }

        return HyperAssetAmount({ evm: amountEVM, core: amountCore, coreBalanceAssetBridge: _assetBridgeSupply });
    }

    /**
     * @notice Computes hyperAssetAmount when EVM decimals > Core decimals
     * @notice Reverts if the transfers amount exceeds the asset bridge balance
     * @param _amount The amount to convert
     * @param _maxTransferableCoreAmount The maximum transferrable amount capped by the asset bridge has range [0,u64.max]
     * @param _decimalDiff The decimal difference between HyperEVM and HyperCore
     * @return amountEVM The EVM amount
     * @return amountCore The core amount
     */
    function into_hyperAssetAmount_decimal_difference_gt_zero(
        uint256 _amount,
        uint64 _maxTransferableCoreAmount,
        uint8 _decimalDiff
    ) internal pure returns (uint256 amountEVM, uint64 amountCore) {
        uint256 scale = 10 ** _decimalDiff;
        uint256 maxAmt = _maxTransferableCoreAmount * scale;

        unchecked {
            /// @dev Strip out dust from _amount so that _amount and maxEvmAmountFromCoreMax have a maximum of _decimalDiff starting 0s
            amountEVM = _amount - (_amount % scale); // Safe: dustAmt = _amount % scale, so dust <= _amount

            if (amountEVM > maxAmt) revert TransferAmtExceedsAssetBridgeBalance(amountEVM, maxAmt);

            /// @dev Safe: Guaranteed to be in the range of [0, u64.max] because it is upperbounded by uint64 maxAmt
            amountCore = uint64(amountEVM / scale);
        }
    }

    /**
     * @notice Computes hyperAssetAmount when EVM decimals < Core decimals and 0
     * @notice Reverts if the transfers amount exceeds the asset bridge balance
     * @param _amount The amount to convert
     * @param _maxTransferableCoreAmount The maximum transferrable amount capped by the asset bridge
     * @param _decimalDiff The decimal difference between HyperEVM and HyperCore
     * @return amountEVM The EVM amount
     * @return amountCore The core amount
     */
    function into_hyperAssetAmount_decimal_difference_leq_zero(
        uint256 _amount,
        uint64 _maxTransferableCoreAmount,
        uint8 _decimalDiff
    ) internal pure returns (uint256 amountEVM, uint64 amountCore) {
        uint256 scale = 10 ** _decimalDiff;
        uint256 maxAmt = _maxTransferableCoreAmount / scale;

        unchecked {
            amountEVM = _amount;

            /// @dev When `Core > EVM` there will be no opening dust to strip out since all tokens in evm can be represented on core
            /// @dev Safe: Bound amountEvm to the range of [0, evmscaled u64.max]
            if (_amount > maxAmt) revert TransferAmtExceedsAssetBridgeBalance(amountEVM, maxAmt);

            /// @dev Safe: Guaranteed to be in the range of [0, u64.max] because it is upperbounded by uint64 maxAmt
            amountCore = uint64(amountEVM * scale);
        }
    }
}
