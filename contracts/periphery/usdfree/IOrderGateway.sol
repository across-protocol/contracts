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
    bytes submitter;
    uint256 deadline;
    bytes srcActions;
    BridgeProtocol bridgeProtocol;
    bytes bridgeData;
}

struct RequirementConfig {
    address handler; // IRequirementHandler implementation
    bytes params; // Handler-specific params
}

struct SubmitterDataInput {
    address handler; // Which requirement handler this data is for
    bytes data; // Handler-specific data (signatures, proofs, etc.)
}

struct AuctionResult {
    bytes32 orderHash; // Hash of (order, requirements, salt) - NOT including submitter
    address winningSubmitter; // Address that won the auction
    uint32 auctionDeadline; // Deadline for submitting this auction result
    bytes backendSignature; // Backend signature over (orderHash, winningSubmitter, auctionDeadline)
}

struct FillParams {
    uint256 localKey;
    uint256 fillAmount; // Relayer's contribution
    bytes32 repaymentAddress;
    uint256 repaymentChainId;
}

interface IOrderGateway {
    // Submit a cross-chain order (submitter is msg.sender, verified via user signature)
    // User signs over: (order, requirements, submitter, salt)
    // Submitter provides: tokenInput + dataInputs at tx time
    function submitOrder(
        Intent calldata intent,
        RequirementConfig[] calldata requirements, // From user
        SubmitterDataInput[] calldata dataInputs, // From submitter (matched by handler)
        bytes32 salt
    ) external payable;

    // For auction orders, orderSignature signs over (order, requirements, salt) WITHOUT submitter
    // auctionResult contains backend signature verifying the winning submitter
    function submitOrder(
        Intent calldata intent,
        RequirementConfig[] calldata requirements,
        SubmitterDataInput[] calldata dataInputs,
        bytes32 salt,
        bytes calldata orderSignature,
        AuctionResult calldata auctionResult // Optional: empty for non-auction orders
    ) external payable;

    // Submit with EIP-2612 permit (gasless)
    function submitOrderWithPermit(
        Intent calldata intent,
        RequirementConfig[] calldata requirements,
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
        Intent calldata intent,
        RequirementConfig[] calldata requirements,
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

interface IOrderStore {
    // Receive intent from bridge - automatically executes if funds sufficient, stores otherwise
    // Called by authorized bridge receivers (CCTP Finalizer, OFT lzCompose handler)
    function receiveOrder(
        Order calldata order,
        address handler // OrderHandler to execute if funds sufficient
    ) external returns (uint256 localKey, bool executed);

    // Relayer fills stored order (provides additional funds to meet outputAmount)
    function fillOrder(uint256 localKey, FillParams calldata fillParams) external;
}

interface IOrderHandler is AcrossMessageHandler {
    // Legacy interface (from AcrossMessageHandler)
    // function handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes memory message) external;

    // Extended interface with orderId context
    function handleOrder(address token, uint256 amount, address relayer, bytes calldata message) external;

    // Multi-hop support (A->B->C)
    function handleOrderWithHop(
        address token,
        uint256 amount,
        address relayer,
        bytes calldata message,
        Intent calldata nextHop
    ) external;
}
