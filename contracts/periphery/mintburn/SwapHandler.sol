//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { FinalTokenInfo } from "./Structs.sol";

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

    function activateCoreAccount(
        address erc20EVMAddress,
        uint64 erc20CoreIndex,
        uint256 amountEVM,
        int8 decimalDiff
    ) external onlyParentHandler {
        HyperCoreLib.transferERC20EVMToSelfOnCore(erc20EVMAddress, erc20CoreIndex, amountEVM, decimalDiff);
    }

    function transferFundsToSelfOnCore(
        address erc20EVMAddress,
        uint64 erc20CoreIndex,
        uint256 amountEVM,
        int8 decimalDiff
    ) external onlyParentHandler {
        HyperCoreLib.transferERC20EVMToSelfOnCore(erc20EVMAddress, erc20CoreIndex, amountEVM, decimalDiff);
    }

    function transferFundsToUserOnCore(
        uint64 erc20CoreIndex,
        address to,
        uint64 amountCore
    ) external onlyParentHandler {
        HyperCoreLib.transferERC20CoreToCore(erc20CoreIndex, to, amountCore);
    }

    function submitSpotLimitOrder(
        FinalTokenInfo memory finalTokenInfo,
        uint64 limitPriceX1e8,
        uint64 sizeX1e8,
        uint128 cloid
    ) external onlyParentHandler {
        HyperCoreLib.submitLimitOrder(
            finalTokenInfo.spotIndex + SPOT_MARKET_INDEX_OFFSET,
            finalTokenInfo.isBuy,
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
