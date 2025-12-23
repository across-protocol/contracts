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
    // Bridge buffer to use when checking safety of bridging evm -> core. In core units
    uint64 bridgeSafetyBufferCore;
}

struct FinalTokenInfo {
    // The index of the market where we're going to swap baseToken -> finalToken
    uint32 spotIndex;
    // To go baseToken -> finalToken, do we have to enqueue a buy or a sell?
    bool isBuy;
    // The fee Hyperliquid charges for Limit orders in the market; in parts per million, e.g. 1.4 bps = 140 ppm
    uint32 feePpm;
    // When enqueuing a limit order, use this to set a price "a bit worse than market" for faster execution
    uint32 suggestedDiscountBps;
    // Contract where the accounting for all baseToken -> finalToken accounting happens. One pre finalToken
    SwapHandler swapHandler;
}

/// @notice Common parameters shared across flow execution functions
struct CommonFlowParams {
    uint256 amountInEVM;
    bytes32 quoteNonce;
    address finalRecipient;
    address finalToken;
    uint256 maxBpsToSponsor;
    uint256 extraFeesIncurred;
}

/// @notice Parameters for executing flows with arbitrary EVM actions
struct EVMFlowParams {
    CommonFlowParams commonParams;
    address initialToken;
    bytes actionData;
    bool transferToCore;
}
