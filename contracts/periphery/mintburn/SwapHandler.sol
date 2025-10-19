//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { FinalTokenInfo } from "./Structs.sol";

contract SwapHandler {
    address public immutable parentHandler;

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

    function submitLimitOrder(
        FinalTokenInfo memory finalTokenInfo,
        uint64 limitPriceX1e8,
        uint64 sizeX1e8,
        uint128 cloid
    ) external onlyParentHandler {
        HyperCoreLib.submitLimitOrder(
            finalTokenInfo.assetIndex,
            finalTokenInfo.isBuy,
            limitPriceX1e8,
            sizeX1e8,
            false,
            HyperCoreLib.Tif.GTC,
            cloid
        );
    }

    function cancelOrderByCloid(uint32 assetIndex, uint128 cloid) external onlyParentHandler {
        HyperCoreLib.cancelOrderByCloid(assetIndex, cloid);
    }

    function sweepErc20(address token, uint256 amount) external onlyParentHandler {
        IERC20(token).transfer(msg.sender, amount);
    }
}
