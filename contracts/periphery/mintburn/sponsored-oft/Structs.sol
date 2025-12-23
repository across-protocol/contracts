// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

/// @notice Execution modes for the sponsored OFT flow
enum ExecutionMode {
    // Send to core and perform swap (if needed) there.
    DirectToCore,
    // Execute arbitrary actions (like a swap) on HyperEVM, then transfer to HyperCore
    ArbitraryActionsToCore,
    // Execute arbitrary actions on HyperEVM only (no HyperCore transfer)
    ArbitraryActionsToEVM
}

/// @notice A structure with all the relevant information about a particular sponsored bridging flow order
struct Quote {
    SignedQuoteParams signedParams;
    UnsignedQuoteParams unsignedParams;
}

/// @notice Signed params of the sponsored bridging flow quote
struct SignedQuoteParams {
    uint32 srcEid; // Source endpoint ID in OFT system.
    // Params passed into OFT.send()
    uint32 dstEid; // Destination endpoint ID in OFT system.
    bytes32 destinationHandler; // `to`. Recipient address. Address of our Composer contract
    uint256 amountLD; // Amount to send in local decimals.
    // Signed params that go into `composeMsg`
    bytes32 nonce; // quote nonce
    uint256 deadline; // quote deadline
    uint256 maxBpsToSponsor; // max bps (of sent amount) to sponsor for 1:1
    bytes32 finalRecipient; // user address on destination
    bytes32 finalToken; // final token user will receive (might be different from OFT token we're sending)
    // Signed gas limits for destination-side LZ execution
    uint256 lzReceiveGasLimit; // gas limit for `lzReceive` call on destination side
    uint256 lzComposeGasLimit; // gas limit for `lzCompose` call on destination side
    // Execution mode and action data
    uint8 executionMode; // ExecutionMode: DirectToCore, ArbitraryActionsToCore, or ArbitraryActionsToEVM
    bytes actionData; // Encoded action data for arbitrary execution. Empty for DirectToCore mode.
}

/// @notice Unsigned params of the sponsored bridging flow quote: user is free to choose these
struct UnsignedQuoteParams {
    address refundRecipient; // recipient of extra msg.value passed into the OFT send on src chain
    uint256 maxUserSlippageBps; // slippage tolerance for the swap on the destination
}
