//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { CoreTokenInfo } from "./Structs.sol";

contract SwapHandler {
    address public immutable parentHandler;

    constructor() {
        parentHandler = msg.sender;
    }

    modifier onlyParentHandler() {
        require(msg.sender == parentHandler, "Not parent handler");
        _;
    }

    function swap(
        CoreTokenInfo memory coreTokenInfo,
        address recipient,
        uint256 amount,
        uint64 limitPriceX1e8,
        uint64 sizeX1e8,
        uint128 cloid
    ) external onlyParentHandler {
        HyperCoreLib.transferERC20EVMToCore(
            coreTokenInfo.evmContract,
            coreTokenInfo.coreIndex,
            recipient,
            amount,
            coreTokenInfo.decimalDiff
        );

        // Submit the limit order to HyperCore
        HyperCoreLib.submitLimitOrder(
            coreTokenInfo.assetIndex,
            coreTokenInfo.isBuy,
            limitPriceX1e8,
            sizeX1e8,
            false,
            HyperCoreLib.Tif.GTC,
            cloid
        );
    }
}
