// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { SwapHandler } from "./SwapHandler.sol";

// Info about the token on HyperCore.
struct CoreTokenInfo {
    // The token info on HyperCore.
    HyperCoreLib.TokenInfo tokenInfo;
    // The HyperCore index id of the token.
    uint64 coreIndex;
    // Whether the token can be used for account activation fee.
    bool canBeUsedForAccountActivation;
    // The account activation fee for the token.
    uint256 accountActivationFeeEVM;
    // The account activation fee for the token on Core.
    uint64 accountActivationFeeCore;
}

struct FinalTokenInfo {
    // The index of the market where we're going to swap baseToken -> finalToken
    uint32 assetIndex;
    // To go baseToken -> finalToken, do we have to enqueue a buy or a sell?
    bool isBuy;
    // The fee Hyperliquid charges for Limit orders in the market; in parts per million, e.g. 1.4 bps = 140 ppm
    uint32 feePpm;
    // When enqueuing a limit order, use this to set a price "a bit worse than market" for faster execution
    uint32 suggestedSlippageBps;
    // Contract where the accounting for all baseToken -> finalToken accounting happens. One pre finalToken
    SwapHandler swapHandler;
}

struct LimitOrder {
    // The client order id of the order.
    uint128 cloid;
    // The limit price of the order scaled by 1e8.
    uint64 limitPriceX1e8;
    // The size of the order scaled by 1e8.
    uint64 sizeX1e8;
}
