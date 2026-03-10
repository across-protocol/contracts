// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct Step {
    address executor;
    bytes message;
}

struct Path {
    Step cur;
    bytes next;
}

// Note: Order is a Merkle tree of Paths + refund settings
struct Order {
    bytes32 root;
    address refundRecipient;
    uint256 refundReverseDeadline;
}

struct TokenAmount {
    address token;
    uint256 amount;
}

struct SubmitterData {
    TokenAmount[] extraFunding;
    bytes executorMessage;
}

// Commits destination-side execution semantics (e.g. swap route/action payload).
struct DestinationAction {
    // Hash of the destination execution payload (for example path.next or step-specific executor message).
    bytes32 actionHash;
    // User protection on the destination leg after executing `actionHash`.
    TokenAmount minOut;
}

// Terms for submitter pre-funding on destination prior to bridge message arrival.
struct PrefundTerms {
    // Asset and amount the submitter fronts to the user before bridge arrival.
    TokenAmount prefund;
    // Asset and minimum amount submitter must be reimbursed with during settlement.
    TokenAmount minReimbursement;
    // Expiry for pre-fund validity; after this, pre-fund can be unwound/refunded by policy.
    uint256 expiry;
    // Hash of deterministic reimbursement route constraints to avoid route ambiguity.
    bytes32 reimbursementPathHash;
}

// Deterministic cross-chain order key used by pre-funders and destination settlement.
// This is intentionally separate from funding-specific orderId generation.
struct IntentKey {
    uint256 srcChainId;
    address srcGateway;
    address user;
    bytes32 userSalt;
}

struct TypedData {
    uint8 typ;
    bytes data;
}

enum OrderFundingType {
    Approval,
    Permit2,
    TransferWithAuthorization
}

enum BridgeType {
    OFT,
    CCTP
}

struct ApprovalFunding {
    TokenAmount tokenAmount;
    bytes32 salt;
}

struct Permit2Funding {
    address signer;
    TokenAmount tokenAmount;
    uint256 nonce;
    uint256 deadline;
    bytes signature;
}

struct AuthorizationFunding {
    address signer;
    TokenAmount tokenAmount;
    uint256 validAfter;
    uint256 validBefore;
    bytes signature;
    bytes32 salt;
}

interface IOrderGateway {
    // Note: submit stores funded Order and waits for a later fill or refund.
    function submit(Order calldata order, TypedData calldata orderFunding) external; // nonReentrant

    // Note: this entrypoint has `submitterData` and therefore should always be able to atomically execute a `Step`
    function submitWithData(
        Order calldata order,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        TypedData calldata orderFunding,
        SubmitterData calldata submitterData
    ) external payable; // nonReentrant

    function fill(
        bytes32 orderId,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        SubmitterData calldata submitterData
    ) external payable;

    // Permissionless after order.refundReverseDeadline, transfers funds to order.refundRecipient.
    function refund(bytes32 orderId) external;
}

interface IOrderGatewayPrefund {
    struct ExpectedBridge {
        BridgeType bridgeType;
        bytes32 bridgeId;
        uint32 srcDomain;
        bytes32 srcSender;
    }

    struct BridgeArrival {
        BridgeType bridgeType;
        bytes32 bridgeId;
        uint32 srcDomain;
        bytes32 srcSender;
        TokenAmount bridgedAmount;
    }

    event Prefunded(
        bytes32 indexed subOrderId,
        address indexed sponsor,
        address indexed token,
        uint256 amount,
        bytes32 orderRoot
    );

    event BridgeMessageArrived(
        bytes32 indexed subOrderId,
        bytes32 indexed bridgeId,
        uint8 bridgeType,
        uint32 srcDomain,
        bytes32 srcSender,
        address token,
        uint256 amount
    );

    event PrefundedOrderSettled(bytes32 indexed subOrderId, address reimbursementToken, uint256 reimbursementAmount);

    // Called by a submitter/sponsor before or after bridge arrival on destination.
    // If the bridge already arrived, this call finalizes immediately.
    function prefund(
        bytes32 subOrderId,
        bytes32 orderRoot,
        ExpectedBridge calldata expectedBridge,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        SubmitterData calldata submitterData,
        PrefundTerms calldata prefundTerms,
        address refundTo
    ) external payable;

    // Called by bridge receiver path (for example OFT/LZ or CCTP) when funds land on destination.
    // If the intent is already prefunded, this call finalizes immediately (including executor call).
    function onBridgeArrival(
        bytes32 subOrderId,
        BridgeArrival calldata arrival,
        PrefundTerms calldata prefundTerms
    ) external;
}

interface IExecutor {
    function execute(
        bytes32 orderId,
        TokenAmount calldata orderIn,
        Path calldata path,
        address submitter,
        bytes calldata submitterData
    ) external payable; // onlyAuthorizedCaller (OrderStore / OrderGateway)
}

interface IUserActionExecutor {
    function executeAndForward(
        bytes32 orderId,
        TokenAmount calldata amountIn,
        bytes calldata message,
        bytes calldata next
    ) external payable;
}
