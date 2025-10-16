// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";

// Info about the token on HyperCore.
struct CoreTokenInfo {
    // The token info on HyperCore.
    HyperCoreLib.TokenInfo tokenInfo;
    // The HyperCore index id of the token.
    uint64 coreIndex;
    // Whether the token can be used for account activation fee.
    bool canBeUsedForAccountActivation;
    // The account activation fee for the token.
    uint256 accountActivationFee;
}

// struct

struct LimitOrder {
    // The client order id of the order.
    uint128 cloid;
    // The limit price of the order scaled by 1e8.
    uint64 limitPriceX1e8;
    // The size of the order scaled by 1e8.
    uint64 sizeX1e8;
}
