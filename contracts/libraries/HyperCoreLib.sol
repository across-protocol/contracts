// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { HyperLiquidHelperLib } from "./HyperLiquidHelperLib.sol";

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

library HyperCoreLib {
    using SafeERC20 for IERC20;
    using HyperLiquidHelperLib for *;

    // Precompile addresses
    address public constant CORE_WRITER_PRECOMPILE_ADDRESS = 0x3333333333333333333333333333333333333333;

    // CoreWriter action headers
    bytes4 public constant LIMIT_ORDER_HEADER = 0x01000001; // version=1, action=1
    bytes4 public constant SPOT_SEND_HEADER = 0x01000006; // version=1, action=6
    bytes4 public constant CANCEL_BY_CLOID_HEADER = 0x0100000B; // version=1, action=11

    error LimitPxIsZero();
    error OrderSizeIsZero();
    error InvalidTif();

    /**
     * @notice Transfer `amountEVM` of `erc20` from HyperEVM to `to` on HyperCore.
     * @dev Returns the amount credited on Core in Core units (post conversion).
     * @dev The decimal difference is evmDecimals - coreDecimals
     */
    function transferERC20ToCore(
        address erc20EVMAddress,
        uint64 erc20CoreIndex,
        address to,
        uint256 amountEVM,
        int8 decimalDiff
    ) internal returns (uint64 amountCore) {
        // if the transfer amount exceeds the bridge balance, this wil revert
        HyperLiquidHelperLib.HyperAssetAmount memory amounts = HyperLiquidHelperLib.quoteHyperCoreAmount(
            erc20CoreIndex,
            decimalDiff,
            erc20CoreIndex.into_assetBridgeAddress(),
            amountEVM
        );

        if (amounts.evm != 0) {
            // Transfer the tokens to this contract's address on HyperCore
            IERC20(erc20EVMAddress).safeTransfer(erc20CoreIndex.into_assetBridgeAddress(), amounts.evm);

            // Transfer the tokens from this contract on HyperCore to the `to` address on HyperCore
            transferERC20OnCore(erc20CoreIndex, to, amounts.core);

            return amounts.core;
        }

        return 0;
    }

    /**
     * @notice Transfers tokens from this contract on HyperCore to
     * @notice the `to` address on HyperCore using the CoreWriter precompile
     * @param erc20CoreIndex The core index of the token
     * @param to The address to receive tokens on HyperCore
     * @param amountCore The amount to transfer on HyperCore
     */
    function transferERC20OnCore(uint64 erc20CoreIndex, address to, uint64 amountCore) internal {
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

        // Encode the action
        bytes memory encodedAction = abi.encode(asset, isBuy, limitPriceX1e8, sizeX1e8, reduceOnly, encodedTif, cloid);

        // Prefix with the limit-order header
        bytes memory data = abi.encodePacked(LIMIT_ORDER_HEADER, encodedAction);

        // Enqueue limit order to HyperCore via CoreWriter precompile
        ICoreWriter(CORE_WRITER_PRECOMPILE_ADDRESS).sendRawAction(data);
    }

    /**
     * @notice Enqueue a cancel-order-by-CLOID for a given asset.
     */
    function cancelOrderByCloid(uint32 asset, uint128 cloid) internal {
        // Encode the action
        bytes memory encodedAction = abi.encode(asset, cloid);

        // Prefix with the cancel-by-cloid header
        bytes memory data = abi.encodePacked(CANCEL_BY_CLOID_HEADER, encodedAction);

        // Enqueue cancel order by CLOID to HyperCore via CoreWriter precompile
        ICoreWriter(CORE_WRITER_PRECOMPILE_ADDRESS).sendRawAction(data);
    }
}
