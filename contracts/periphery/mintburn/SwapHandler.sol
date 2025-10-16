//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { CoreTokenInfo } from "./Structs.sol";
import { FinalTokenParams } from "./Structs.sol";

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

    function submitLimitOrder(
        FinalTokenParams memory finalTokenParams,
        uint64 limitPriceX1e8,
        uint64 sizeX1e8,
        uint128 cloid
    ) external onlyParentHandler {
        HyperCoreLib.submitLimitOrder(
            finalTokenParams.assetIndex,
            finalTokenParams.isBuy,
            limitPriceX1e8,
            sizeX1e8,
            false,
            HyperCoreLib.Tif.GTC,
            cloid
        );
    }
}
