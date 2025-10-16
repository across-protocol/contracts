// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Info about the token on HyperCore.
struct CoreTokenInfo {
    // The EVM contract address of the token.
    address evmContract;
    // The HyperCore index id of the token.
    uint64 coreIndex;
    // The decimal difference of evmDecimals - coreDecimals.
    int8 decimalDiff;
    // The asset index of the token on HyperCore.
    uint32 assetIndex;
    // Whether the order is a buy order.
    bool isBuy;
    // The swap handler contract address.
    address swapHandler;
}

struct LimitOrder {
    // The client order id of the order.
    uint128 cloid;
    // The limit price of the order scaled by 1e8.
    uint64 limitPriceX1e8;
    // The size of the order scaled by 1e8.
    uint64 sizeX1e8;
}
