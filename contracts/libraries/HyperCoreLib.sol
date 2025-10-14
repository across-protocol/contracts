// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// TODO: handle MIT / BUSL license

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

    struct LimitOrder {
        uint32 asset;
        bool isBuy;
        uint64 limitPx1e8; // price scaled by 1e8
        uint64 sz1e8; // size  scaled by 1e8
        bool reduceOnly;
        uint8 encodedTif; // 1 = ALO, 2 = GTC, 3 = IOC
        uint128 cloid; // 0 => no client order id
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold; // Unused in this implementation
        uint64 entryNtl; // Unused in this implementation
    }

    struct CoreUserExists {
        bool exists;
    }

    address public constant SPOT_BALANCE_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000801;
    address public constant CORE_USER_EXISTS_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000810;
    address public constant CORE_WRITER_PRECOMPILE_ADDRESS = 0x3333333333333333333333333333333333333333;
    address public constant BASE_ASSET_BRIDGE_ADDRESS = 0x2000000000000000000000000000000000000000;
    uint256 public constant BASE_ASSET_BRIDGE_ADDRESS_UINT256 = uint256(uint160(BASE_ASSET_BRIDGE_ADDRESS));
    bytes4 public constant SPOT_SEND_HEADER = 0x01000006;

    error TransferAmtExceedsAssetBridgeBalance(uint256 amt, uint256 maxAmt);
    error SpotBalancePrecompileCallFailed();
    error CoreUserExistsPrecompileCallFailed();
    error CoreUserNotActivated();

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

        // TODO: removed check if user is not activated on HyperCore

        if (amounts.evm != 0) {
            // Transfer the tokens to this contract's address on HyperCore
            IERC20(erc20).safeTransfer(into_assetBridgeAddress(erc20HCIndex), amounts.evm);

            // Transfer the tokens from this contract on HyperCore to the `to` address on HyperCore
            _submitCoreWriterTransfer(to, erc20HCIndex, amounts.core);
        }

        return amounts.core;
    }

    /**
     * @notice Transfers tokens on HyperCore using the CoreWriter precompile
     * @param _to The address to receive tokens on HyperCore
     * @param _coreIndex The core index of the token
     * @param _coreAmount The amount to transfer on HyperCore
     */
    function _submitCoreWriterTransfer(address _to, uint64 _coreIndex, uint64 _coreAmount) internal {
        bytes memory action = abi.encode(_to, _coreIndex, _coreAmount);
        bytes memory payload = abi.encodePacked(SPOT_SEND_HEADER, action);
        /// Transfers HYPE tokens from the composer address on HyperCore to the _to via the SpotSend precompile
        ICoreWriter(CORE_WRITER_PRECOMPILE_ADDRESS).sendRawAction(payload);
    }

    // /**
    //  * @notice Checks if the receiver's address is activated on HyperCore
    //  * @notice To be overriden on FeeToken or other implementations since this can be used to activate tokens
    //  * @dev Default behavior is to revert if the user's account is NOT activated
    //  * @param _to The address to check
    //  * @param _coreAmount The core amount to transfer
    //  * @return The final core amount to transfer (same as _coreAmount in default impl)
    //  */
    // // TODO: clean this up, don't need this function probably
    // function _getFinalCoreAmount(address _to, uint64 _coreAmount) internal view returns (uint64) {
    //     if (!coreUserExists(_to)) revert CoreUserNotActivated();
    //     return _coreAmount;
    // }

    /**
     * @notice Transfer `amountHCDecimals` of `erc20` from this contract on HyperCore to `to` on HyperCore.
     */
    function transferERC20OnHC(address to, uint64 erc20HCIndex, uint64 amountHCDecimals) internal {}

    /**
     * @notice Enqueue a limit order on HyperCore.
     */
    function enqueueLimitOrder(LimitOrder calldata order) internal {}

    /**
     * @notice Quotes the conversion of evm tokens to hypercore tokens
     * @param _coreIndexId The core index id of the token to transfer
     * @param _decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @param _bridgeAddress The asset bridge address of the token to transfer
     * @param _amountLD The number of tokens that the composer received (pre-dusted) that we are trying to send
     * @return IHyperAssetAmount - The amount of tokens to send to HyperCore (scaled on evm), dust (to be refunded), and the swap amount (of the tokens scaled on hypercore)
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
     * @notice Converts a core index id to an asset bridge address
     * @notice This function is called by the HyperLiquidComposer contract
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
     * @notice This function is called by the HyperLiquidComposer contract
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

    function coreUserExists(address user) internal view returns (bool) {
        (bool success, bytes memory result) = CORE_USER_EXISTS_PRECOMPILE_ADDRESS.staticcall(abi.encode(user));
        if (!success) revert CoreUserExistsPrecompileCallFailed();
        CoreUserExists memory _coreUserExists = abi.decode(result, (CoreUserExists));
        return _coreUserExists.exists;
    }
}
