// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";

contract SwapHandler {
    // See https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint#asset
    uint32 private constant SPOT_MARKET_INDEX_OFFSET = 10_000;

    address public immutable parentHandler;
    using SafeERC20 for IERC20;

    constructor() {
        parentHandler = msg.sender;
    }

    modifier onlyParentHandler() {
        require(msg.sender == parentHandler, "Not parent handler");
        _;
    }

    function transferFundsToSelfOnCore(
        address erc20EVMAddress,
        uint64 erc20CoreIndex,
        uint256 amountEVM,
        int8 decimalDiff
    ) external onlyParentHandler {
        HyperCoreLib.transferERC20EVMToSelfOnSpot(erc20EVMAddress, erc20CoreIndex, amountEVM, decimalDiff);
    }

    function transferFundsToUserOnCore(
        uint64 erc20CoreIndex,
        address to,
        uint64 amountCore,
        uint32 destinationDex
    ) external onlyParentHandler {
        HyperCoreLib.transferERC20CoreToCore(
            erc20CoreIndex,
            to,
            amountCore,
            HyperCoreLib.CORE_SPOT_DEX_ID,
            destinationDex
        );
    }

    function submitSpotLimitOrder(
        uint32 spotIndex,
        bool isBuy,
        uint64 limitPriceX1e8,
        uint64 sizeX1e8,
        uint128 cloid
    ) external onlyParentHandler {
        HyperCoreLib.submitLimitOrder(
            spotIndex + SPOT_MARKET_INDEX_OFFSET,
            isBuy,
            limitPriceX1e8,
            sizeX1e8,
            false,
            HyperCoreLib.Tif.GTC,
            cloid
        );
    }

    function cancelOrderByCloid(uint32 spotIndex, uint128 cloid) external onlyParentHandler {
        HyperCoreLib.cancelOrderByCloid(spotIndex + SPOT_MARKET_INDEX_OFFSET, cloid);
    }

    function sweepErc20(address token, uint256 amount) external onlyParentHandler {
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
