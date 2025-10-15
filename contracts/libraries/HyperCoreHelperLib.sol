// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library HyperCoreHelperLib {
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
    address public constant CORE_USER_EXISTS_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000810;
    address constant TOKEN_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080C;

    error SpotBalancePrecompileCallFailed();
    error CoreUserExistsPrecompileCallFailed();
    error TokenInfoPrecompileCallFailed();
    error TransferAmtExceedsAssetBridgeBalance(uint256 amt, uint256 maxAmt);

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
        return into_hyperAssetAmount(amountEVM, spotBalance(bridgeAddress, erc20CoreIndex), decimalDiff);
    }

    /**
     * @notice Converts a core index id to an asset bridge address
     * @param erc20CoreIndex The core token index id to convert
     * @return assetBridgeAddress The asset bridge address
     */
    function into_assetBridgeAddress(uint64 erc20CoreIndex) internal pure returns (address) {
        return address(uint160(BASE_ASSET_BRIDGE_ADDRESS_UINT256 + erc20CoreIndex));
    }

    /**
     * @notice Converts an asset bridge address to a core index id
     * @param assetBridgeAddress The asset bridge address to convert
     * @return erc20CoreIndex The core token index id
     */
    function into_tokenId(address assetBridgeAddress) internal pure returns (uint64) {
        return uint64(uint160(assetBridgeAddress) - BASE_ASSET_BRIDGE_ADDRESS_UINT256);
    }

    /**
     * @notice Converts an amount and an asset to a evm amount and core amount
     * @param amountEVMPreDusted The amount to convert
     * @param assetBridgeSupplyCore The maximum amount transferable capped by the number of tokens located on the HyperCore's side of the asset bridge
     * @param decimalDiff The decimal difference of evmDecimals - coreDecimals
     * @return HyperAssetAmount The evm amount and core amount
     */
    function into_hyperAssetAmount(
        uint256 amountEVMPreDusted,
        uint64 assetBridgeSupplyCore,
        int8 decimalDiff
    ) internal pure returns (HyperAssetAmount memory) {
        uint256 amountEVM;
        uint64 amountCore;

        /// @dev HyperLiquid decimal conversion: Scale EVM (u256,evmDecimals) -> Core (u64,coreDecimals)
        /// @dev Core amount is guaranteed to be within u64 range.
        if (decimalDiff > 0) {
            (amountEVM, amountCore) = into_hyperAssetAmount_decimal_difference_gt_zero(
                amountEVMPreDusted,
                assetBridgeSupplyCore,
                uint8(decimalDiff)
            );
        } else {
            (amountEVM, amountCore) = into_hyperAssetAmount_decimal_difference_leq_zero(
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
    function into_hyperAssetAmount_decimal_difference_gt_zero(
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
    function into_hyperAssetAmount_decimal_difference_leq_zero(
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
}
