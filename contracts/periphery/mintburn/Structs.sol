// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SwapHandler } from "./SwapHandler.sol";

enum AccountCreationMode {
    Standard,
    FromUserFunds
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
    uint32 destinationDex;
    AccountCreationMode accountCreationMode;
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
