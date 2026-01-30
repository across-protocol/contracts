//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

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
