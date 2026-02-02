//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Structs

enum BridgeProtocol {
    SpokePool,
    CCTP,
    OFT
}

struct Intent {
    address user;
    bytes32 inputToken;
    uint256 inputAmount;
    BridgeProtocol bridgeProtocol;
    bytes bridgeData; // Protocol-specific params
}

struct Intent2 {
    address user;
    bytes32 inputToken;
    uint256 inputAmount;
    bytes32 outputToken;
    uint256 outputAmount;
    uint256 destinationChainId;
    bytes32 recipient;
    uint32 fillDeadline;
    bytes32 exclusiveRelayer;
    uint32 exclusivityDeadline;
}

struct SponsoredCCTPQuote {
    // The domain ID of the source chain.
    uint32 sourceDomain;
    // The domain ID of the destination chain.
    uint32 destinationDomain;
    // The recipient of the minted USDC on the destination chain.
    bytes32 mintRecipient;
    // The amount that the user pays on the source chain.
    uint256 amount;
    // The token that will be burned on the source chain.
    bytes32 burnToken;
    // The caller of the destination chain.
    bytes32 destinationCaller;
    // Maximum fee to pay on the destination domain, specified in units of burnToken
    uint256 maxFee;
    // Minimum finality threshold before allowed to attest
    uint32 minFinalityThreshold;
    // Nonce is used to prevent replay attacks.
    bytes32 nonce;
    // Timestamp of the quote after which it can no longer be used.
    uint256 deadline;
    // The maximum basis points of the amount that can be sponsored.
    uint256 maxBpsToSponsor;
    // Slippage tolerance for the fees on the destination. Used in swap flow, enforced on destination
    uint256 maxUserSlippageBps;
    // The final recipient of the sponsored deposit. This is needed as the mintRecipient will be the
    // handler contract address instead of the final recipient.
    bytes32 finalRecipient;
    // The final token that final recipient will receive. This is needed as it can be different from the burnToken
    // in which case we perform a swap on the destination chain.
    bytes32 finalToken;
    // Execution mode: DirectToCore, ArbitraryActionsToCore, or ArbitraryActionsToEVM
    uint8 executionMode;
    // Encoded action data for arbitrary execution. Empty for DirectToCore mode.
    bytes actionData;
}

// relayer hits Order store in all three cases
// can OrderStore have flash loan style flow
// relayer can't approve a contract that can do arbitraty actions
// fill method with relayer

// user sends funds
//

interface IOrderGateway {
    // Submit a cross-chain order (submitter is msg.sender, verified via user signature)
    // User signs over: (order, requirements, submitter, salt)
    // Submitter provides: tokenInput + dataInputs at tx time
    function submitOrder(
        Order calldata order,
        RequirementConfig[] calldata requirements, // From user
        SubmitterTokenInput calldata tokenInput, // From submitter (at tx time)
        SubmitterDataInput[] calldata dataInputs, // From submitter (matched by handler)
        bytes32 salt
    ) external payable;

    // For auction orders, orderSignature signs over (order, requirements, salt) WITHOUT submitter
    // auctionResult contains backend signature verifying the winning submitter
    function submitOrder(
        Order calldata order,
        RequirementConfig[] calldata requirements,
        SubmitterTokenInput calldata tokenInput,
        SubmitterDataInput[] calldata dataInputs,
        bytes32 salt,
        bytes calldata orderSignature,
        AuctionResult calldata auctionResult // Optional: empty for non-auction orders
    ) external payable;

    // Submit with EIP-2612 permit (gasless)
    function submitOrderWithPermit(
        Order calldata order,
        RequirementConfig[] calldata requirements,
        SubmitterTokenInput calldata tokenInput,
        SubmitterDataInput[] calldata dataInputs,
        bytes32 salt,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        bytes calldata orderSignature // User signature over (order, requirements, submitter, salt)
    ) external payable;

    // Submit with Permit2
    function submitOrderWithPermit2(
        Order calldata order,
        RequirementConfig[] calldata requirements,
        SubmitterTokenInput calldata tokenInput,
        SubmitterDataInput[] calldata dataInputs,
        bytes32 salt,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata permitSignature,
        bytes calldata orderSignature // User signature over (order, requirements, submitter, salt)
    ) external payable;

    // Batch submission
    function submitOrderBatch(
        Order[] calldata orders,
        RequirementConfig[] calldata requirements, // Applied to all orders (from user)
        SubmitterTokenInput[] calldata tokenInputs, // Per-order token inputs
        SubmitterDataInput[][] calldata dataInputs, // Per-order data inputs
        bytes32[] calldata salts,
        bytes[] calldata orderSignatures // User signatures for each order
    ) external payable;
}

interface IMetaReqHandler {
    // Validate all requirements then submit to bridge
    // Matches SubmitterDataInput[] to requirements by handler address
    function validateAndSubmit(
        OrderContext calldata orderContext, // order is inside the orderContext
        RequirementConfig[] calldata requirements,
        SubmitterDataInput[] calldata dataInputs
    ) external payable returns (bytes32 bridgeMessageId);

    /** matching logic:
    for each requirement in requirements:
        submitterData = findDataInput(dataInputs, requirement.handler) // empty if not found
        requirement.handler.validateRequirement(orderContext, requirement.params, submitterData)
     */
}

interface IIntentStore {
    // Receive intent from bridge - automatically executes if funds sufficient, stores otherwise
    // Called by authorized bridge receivers (CCTP Finalizer, OFT lzCompose handler)
    function receiveIntent(
        bytes32 orderId,
        Intent calldata intent,
        address handler // IntentHandler to execute if funds sufficient
    ) external returns (uint256 localKey, bool executed);

    // Relayer fills stored intent (provides additional funds to meet outputAmount)
    function fillIntent(uint256 localKey, FillParams calldata fillParams) external;
}

interface IIntentHandler is AcrossMessageHandler {
    // Legacy interface (from AcrossMessageHandler)
    // function handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes memory message) external;

    // Extended interface with orderId context
    function handleIntent(
        bytes32 orderId,
        address token,
        uint256 amount,
        address relayer,
        bytes calldata message
    ) external;

    // Multi-hop support (A->B->C)
    function handleIntentWithHop(
        bytes32 orderId,
        address token,
        uint256 amount,
        address relayer,
        bytes calldata message,
        Order calldata nextHop
    ) external returns (bytes32 nextOrderId);
}
