// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Order, Path, IExecutor, TokenAmount, TypedData, SubmitterData, IOrderGateway, IOrderGatewayPrefund, OrderFundingType, Permit2Funding, AuthorizationFunding, ApprovalFunding, PrefundTerms, IntentKey } from "./Interfaces.sol";
import { OrderIdLib } from "./OrderIdLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { IPermit2 } from "../external/interfaces/IPermit2.sol";
import { IERC20Auth } from "../external/interfaces/IERC20Auth.sol";

contract OrderGateway is
    Initializable,
    IOrderGateway,
    IOrderGatewayPrefund,
    UUPSUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuard,
    AccessControlDefaultAdminRulesUpgradeable
{
    using SafeERC20 for IERC20;

    string public constant EIP712_NAME = "USDFreeOrderGateway";
    string public constant EIP712_VERSION = "1";
    struct PendingOrder {
        TokenAmount orderIn;
        Order order;
        bool exists;
    }
    enum PrefundStatus {
        None,
        Prefunded,
        ExecutedPendingBridge,
        BridgeArrived,
        Executed,
        Refunded
    }

    struct PrefundedIntent {
        bytes32 orderRoot;
        bytes32 dstActionHash;
        PrefundTerms prefundTerms;
        bytes32 expectedBridgeId;
        uint8 expectedBridgeType;
        uint32 expectedSrcDomain;
        bytes32 expectedSrcSender;
        address refundTo;
        address executionSubmitter;
        uint256 executionNativeValue;
        Path selectedPath;
        SubmitterData submitterData;
        TokenAmount bridgedAmount;
        PrefundStatus status;
    }

    IPermit2 public permit2;
    mapping(address => mapping(bytes32 => bool)) public usedApprovalSalts;
    mapping(bytes32 => PendingOrder) internal pendingOrders;
    mapping(bytes32 => PrefundedIntent) internal prefundedIntents;
    mapping(bytes32 => bytes32) public bridgeIdToSubOrderId;
    mapping(address => bool) public isBridgeCaller;
    mapping(uint32 => bytes32) public trustedSrcSenderByDomain;

    bytes32 public constant ORDER_ID_WITNESS_TYPEHASH = keccak256("OrderIdWitness(bytes32 orderId)");
    string public constant PERMIT2_ORDER_WITNESS_TYPE =
        "OrderIdWitness witness)OrderIdWitness(bytes32 orderId)TokenPermissions(address token,uint256 amount)";

    error DuplicateApprovalSalt();
    error InvalidAddress();
    error InvalidExecutor();
    error InvalidSignatureLength();
    error InvalidSubOrder();
    error InvalidSubOrderId();
    error InvalidPrefundAmount();
    error InvalidPrefundToken();
    error InvalidBridgeToken();
    error InvalidBridgeAmount();
    error InvalidState();
    error InvalidActionHash();
    error SubOrderAlreadyProcessed();
    error MinReimbursementNotMet();
    error InsufficientBridgeFunds();
    error UnexpectedBridge();
    error UnauthorizedBridgeCaller();
    error UntrustedSourceSender();
    error DuplicateBridgeId();
    error InvalidPermit2Salt();
    error OrderAlreadyStored();
    error RefundNotReady();
    error InvalidRefundRecipient();
    error UnknownOrderId();
    error UnknownOrderFundingType();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _permit2) external initializer {
        if (_permit2 == address(0)) revert InvalidAddress();
        __EIP712_init(EIP712_NAME, EIP712_VERSION);
        __AccessControlDefaultAdminRules_init(0, _owner);
        permit2 = IPermit2(_permit2);
    }

    // TODO: perhaps this warrants a rename. Since `msg.sender` here does not get recorded as `submitter`. Submitter
    // TODO: is only the one doing `submitWithData` or `fill`. Think about naming
    function submit(Order calldata order, TypedData calldata orderFunding) external nonReentrant {
        (bytes32 orderId, address token, uint256 amount) = _pullOrderFundingAndComputeOrderId(
            order,
            orderFunding,
            address(this)
        );
        if (pendingOrders[orderId].exists) revert OrderAlreadyStored();
        pendingOrders[orderId] = PendingOrder({
            orderIn: TokenAmount({ token: token, amount: amount }),
            order: order,
            exists: true
        });
    }

    function submitWithData(
        Order calldata order,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        TypedData calldata orderFunding,
        SubmitterData calldata submitterData
    ) external payable nonReentrant {
        address executor = selectedPath.cur.executor;
        if (executor == address(0)) revert InvalidExecutor();

        bytes32 leaf = keccak256(abi.encode(selectedPath));
        if (!MerkleProof.verify(pathProof, order.root, leaf)) revert InvalidSubOrder();

        (bytes32 orderId, address token, uint256 amount) = _pullOrderFundingAndComputeOrderId(
            order,
            orderFunding,
            executor
        );

        _pullExtraFundingToExecutor(executor, submitterData.extraFunding);
        IExecutor(executor).execute{ value: msg.value }(
            orderId,
            TokenAmount({ token: token, amount: amount }),
            selectedPath,
            msg.sender,
            submitterData.executorMessage
        );
    }

    function fill(
        bytes32 orderId,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        SubmitterData calldata submitterData
    ) external payable nonReentrant {
        PendingOrder storage pending = pendingOrders[orderId];
        if (!pending.exists) revert UnknownOrderId();

        address executor = selectedPath.cur.executor;
        if (executor == address(0)) revert InvalidExecutor();
        if (!MerkleProof.verify(pathProof, pending.order.root, keccak256(abi.encode(selectedPath))))
            revert InvalidSubOrder();

        TokenAmount memory orderIn = pending.orderIn;
        delete pendingOrders[orderId];

        IERC20(orderIn.token).safeTransfer(executor, orderIn.amount);
        _pullExtraFundingToExecutor(executor, submitterData.extraFunding);
        IExecutor(executor).execute{ value: msg.value }(
            orderId,
            orderIn,
            selectedPath,
            msg.sender,
            submitterData.executorMessage
        );
    }

    function refund(bytes32 orderId) external nonReentrant {
        PendingOrder storage pending = pendingOrders[orderId];
        if (!pending.exists) revert UnknownOrderId();
        if (block.timestamp < pending.order.refundReverseDeadline) revert RefundNotReady();
        if (pending.order.refundRecipient == address(0)) revert InvalidRefundRecipient();

        TokenAmount memory orderIn = pending.orderIn;
        address refundRecipient = pending.order.refundRecipient;
        delete pendingOrders[orderId];
        IERC20(orderIn.token).safeTransfer(refundRecipient, orderIn.amount);
    }

    function prefund(
        bytes32 subOrderId,
        bytes32 orderRoot,
        IOrderGatewayPrefund.ExpectedBridge calldata expectedBridge,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        SubmitterData calldata submitterData,
        PrefundTerms calldata prefundTerms,
        address refundTo
    ) external payable nonReentrant {
        if (!MerkleProof.verify(pathProof, orderRoot, keccak256(abi.encode(selectedPath)))) revert InvalidSubOrder();

        PrefundedIntent storage intent = prefundedIntents[subOrderId];
        if (intent.status == PrefundStatus.Executed || intent.status == PrefundStatus.Refunded)
            revert SubOrderAlreadyProcessed();
        if (intent.status == PrefundStatus.Prefunded || intent.status == PrefundStatus.ExecutedPendingBridge)
            revert InvalidState();

        bytes32 actionHash = _destinationActionHash(selectedPath, submitterData.executorMessage);
        _upsertIntentCommitment(intent, orderRoot, actionHash, prefundTerms);
        _upsertExpectedBridge(intent, expectedBridge);

        IERC20(prefundTerms.prefund.token).safeTransferFrom(msg.sender, address(this), prefundTerms.prefund.amount);

        intent.refundTo = refundTo;
        intent.executionSubmitter = msg.sender;
        intent.executionNativeValue = msg.value;
        _storeExecutionData(intent, selectedPath, submitterData);
        if (_hasEnoughPrefundToExecute(intent)) {
            _executeStoredIntent(subOrderId, intent);
            intent.status = PrefundStatus.ExecutedPendingBridge;
        } else {
            intent.status = PrefundStatus.Prefunded;
        }

        emit Prefunded(subOrderId, msg.sender, prefundTerms.prefund.token, prefundTerms.prefund.amount, orderRoot);
    }

    function onBridgeArrival(
        bytes32 subOrderId,
        IOrderGatewayPrefund.BridgeArrival calldata arrival,
        PrefundTerms calldata prefundTerms
    ) external nonReentrant {
        if (!isBridgeCaller[msg.sender]) revert UnauthorizedBridgeCaller();
        if (trustedSrcSenderByDomain[arrival.srcDomain] != arrival.srcSender) revert UntrustedSourceSender();
        if (bridgeIdToSubOrderId[arrival.bridgeId] != bytes32(0)) revert DuplicateBridgeId();

        PrefundedIntent storage intent = prefundedIntents[subOrderId];
        if (intent.status == PrefundStatus.Executed || intent.status == PrefundStatus.Refunded)
            revert SubOrderAlreadyProcessed();
        if (intent.status != PrefundStatus.Prefunded && intent.status != PrefundStatus.ExecutedPendingBridge)
            revert InvalidState();

        _upsertIntentCommitment(intent, bytes32(0), bytes32(0), prefundTerms);
        if (
            intent.expectedBridgeId != arrival.bridgeId ||
            intent.expectedBridgeType != uint8(arrival.bridgeType) ||
            intent.expectedSrcDomain != arrival.srcDomain ||
            intent.expectedSrcSender != arrival.srcSender
        ) revert UnexpectedBridge();
        intent.bridgedAmount = arrival.bridgedAmount;
        bridgeIdToSubOrderId[arrival.bridgeId] = subOrderId;

        emit BridgeMessageArrived(
            subOrderId,
            arrival.bridgeId,
            uint8(arrival.bridgeType),
            arrival.srcDomain,
            arrival.srcSender,
            arrival.bridgedAmount.token,
            arrival.bridgedAmount.amount
        );

        if (intent.status == PrefundStatus.Prefunded) {
            _executeStoredIntent(subOrderId, intent);
            _settleBridgeToSubmitter(subOrderId, intent);
        } else if (intent.status == PrefundStatus.ExecutedPendingBridge) {
            _settleBridgeToSubmitter(subOrderId, intent);
        }
    }

    function refundPrefund(bytes32 subOrderId) external nonReentrant {
        PrefundedIntent storage intent = prefundedIntents[subOrderId];
        if (intent.status != PrefundStatus.Prefunded && intent.status != PrefundStatus.BridgeArrived)
            revert InvalidState();
        if (intent.prefundTerms.expiry == 0 || block.timestamp <= intent.prefundTerms.expiry) revert RefundNotReady();

        if (intent.prefundTerms.prefund.amount > 0 && intent.prefundTerms.prefund.token != address(0)) {
            IERC20(intent.prefundTerms.prefund.token).safeTransfer(intent.refundTo, intent.prefundTerms.prefund.amount);
        }
        intent.status = PrefundStatus.Refunded;
    }

    function _pullOrderFundingAndComputeOrderId(
        Order calldata order,
        TypedData calldata orderFunding,
        address fundsRecipient
    ) internal returns (bytes32 orderId, address token, uint256 amount) {
        bytes32 _domainHash = _domainSeparatorV4();
        bytes32 orderHash = _orderHash(order);
        OrderFundingType typ = OrderFundingType(orderFunding.typ);

        if (typ == OrderFundingType.Approval) {
            return _pullFundsApproval(_domainHash, orderHash, orderFunding, fundsRecipient);
        }
        if (typ == OrderFundingType.Permit2) {
            return _pullFundsPermit2(_domainHash, orderHash, orderFunding, fundsRecipient);
        }
        if (typ == OrderFundingType.TransferWithAuthorization) {
            return _pullFundsTWA(_domainHash, orderHash, orderFunding, fundsRecipient);
        }

        revert UnknownOrderFundingType();
    }

    function _pullFundsApproval(
        bytes32 _domainHash,
        bytes32 orderHash,
        TypedData calldata orderFunding,
        address fundsRecipient
    ) internal returns (bytes32 orderId, address token, uint256 amount) {
        ApprovalFunding memory f = abi.decode(orderFunding.data, (ApprovalFunding));
        if (usedApprovalSalts[msg.sender][f.salt]) revert DuplicateApprovalSalt();
        usedApprovalSalts[msg.sender][f.salt] = true;
        IERC20(f.tokenAmount.token).safeTransferFrom(msg.sender, fundsRecipient, f.tokenAmount.amount);
        return (
            OrderIdLib.orderId(_domainHash, uint8(OrderFundingType.Approval), msg.sender, orderHash, f.salt),
            f.tokenAmount.token,
            f.tokenAmount.amount
        );
    }

    function _pullFundsPermit2(
        bytes32 _domainHash,
        bytes32 orderHash,
        TypedData calldata orderFunding,
        address fundsRecipient
    ) internal returns (bytes32 orderId, address token, uint256 amount) {
        Permit2Funding memory f = abi.decode(orderFunding.data, (Permit2Funding));
        orderId = OrderIdLib.orderId(
            _domainHash,
            uint8(OrderFundingType.Permit2),
            f.signer,
            orderHash,
            bytes32(f.nonce)
        );
        bytes32 witness = keccak256(abi.encode(ORDER_ID_WITNESS_TYPEHASH, orderId));
        permit2.permitWitnessTransferFrom(
            IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({ token: f.tokenAmount.token, amount: f.tokenAmount.amount }),
                nonce: f.nonce,
                deadline: f.deadline
            }),
            IPermit2.SignatureTransferDetails({ to: fundsRecipient, requestedAmount: f.tokenAmount.amount }),
            f.signer,
            witness,
            PERMIT2_ORDER_WITNESS_TYPE,
            f.signature
        );
        return (orderId, f.tokenAmount.token, f.tokenAmount.amount);
    }

    function _pullFundsTWA(
        bytes32 _domainHash,
        bytes32 orderHash,
        TypedData calldata orderFunding,
        address fundsRecipient
    ) internal returns (bytes32 orderId, address token, uint256 amount) {
        AuthorizationFunding memory f = abi.decode(orderFunding.data, (AuthorizationFunding));
        orderId = OrderIdLib.orderId(
            _domainHash,
            uint8(OrderFundingType.TransferWithAuthorization),
            f.signer,
            orderHash,
            f.salt
        );
        (bytes32 r, bytes32 s, uint8 v) = _deserializeSignature(f.signature);
        IERC20Auth(f.tokenAmount.token).receiveWithAuthorization(
            f.signer,
            fundsRecipient,
            f.tokenAmount.amount,
            f.validAfter,
            f.validBefore,
            orderId,
            v,
            r,
            s
        );
        return (orderId, f.tokenAmount.token, f.tokenAmount.amount);
    }

    function _pullExtraFundingToExecutor(address executor, TokenAmount[] calldata extraFunding) internal {
        _pullExtraFundingToExecutorFrom(msg.sender, executor, extraFunding);
    }

    function _pullExtraFundingToExecutorFrom(
        address funder,
        address executor,
        TokenAmount[] calldata extraFunding
    ) internal {
        for (uint256 i; i < extraFunding.length; ++i) {
            IERC20(extraFunding[i].token).safeTransferFrom(funder, executor, extraFunding[i].amount);
        }
    }

    function _deserializeSignature(bytes memory signature) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        if (signature.length != 65) revert InvalidSignatureLength();
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
    }

    function _orderHash(Order calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }

    function _executeStoredIntent(bytes32 subOrderId, PrefundedIntent storage intent) internal {
        SubmitterData storage submitterData = intent.submitterData;
        address submitter = intent.executionSubmitter;
        Path memory selectedPath = intent.selectedPath;
        bytes memory executorMessage = submitterData.executorMessage;
        address executor = selectedPath.cur.executor;
        if (executor == address(0)) revert InvalidExecutor();
        if (IERC20(intent.prefundTerms.prefund.token).balanceOf(address(this)) < intent.prefundTerms.prefund.amount)
            revert InvalidPrefundAmount();

        IERC20(intent.prefundTerms.prefund.token).safeTransfer(executor, intent.prefundTerms.prefund.amount);
        _pullExtraFundingToExecutorFromStorage(submitter, executor, submitterData.extraFunding);
        IExecutor(executor).execute{ value: intent.executionNativeValue }(
            subOrderId,
            intent.prefundTerms.prefund,
            selectedPath,
            submitter,
            executorMessage
        );
    }

    function _settleBridgeToSubmitter(bytes32 subOrderId, PrefundedIntent storage intent) internal {
        if (intent.bridgedAmount.token != intent.prefundTerms.minReimbursement.token) revert InvalidBridgeToken();
        if (intent.bridgedAmount.amount < intent.prefundTerms.minReimbursement.amount) revert MinReimbursementNotMet();
        if (IERC20(intent.bridgedAmount.token).balanceOf(address(this)) < intent.bridgedAmount.amount)
            revert InsufficientBridgeFunds();

        IERC20(intent.bridgedAmount.token).safeTransfer(intent.refundTo, intent.bridgedAmount.amount);
        intent.status = PrefundStatus.Executed;

        emit PrefundedOrderSettled(subOrderId, intent.bridgedAmount.token, intent.bridgedAmount.amount);
    }

    function _upsertIntentCommitment(
        PrefundedIntent storage intent,
        bytes32 orderRoot,
        bytes32 dstActionHash,
        PrefundTerms calldata prefundTerms
    ) internal {
        if (orderRoot != bytes32(0) && intent.orderRoot == bytes32(0)) {
            intent.orderRoot = orderRoot;
        } else if (orderRoot != bytes32(0) && intent.orderRoot != orderRoot) {
            revert InvalidSubOrderId();
        }

        if (dstActionHash != bytes32(0) && intent.dstActionHash == bytes32(0)) {
            intent.dstActionHash = dstActionHash;
        } else if (dstActionHash != bytes32(0) && intent.dstActionHash != dstActionHash) {
            revert InvalidActionHash();
        }

        if (intent.prefundTerms.prefund.token == address(0)) {
            intent.prefundTerms = prefundTerms;
        } else {
            if (
                intent.prefundTerms.prefund.token != prefundTerms.prefund.token ||
                intent.prefundTerms.prefund.amount != prefundTerms.prefund.amount ||
                intent.prefundTerms.minReimbursement.token != prefundTerms.minReimbursement.token ||
                intent.prefundTerms.minReimbursement.amount != prefundTerms.minReimbursement.amount ||
                intent.prefundTerms.expiry != prefundTerms.expiry ||
                intent.prefundTerms.reimbursementPathHash != prefundTerms.reimbursementPathHash
            ) revert InvalidSubOrderId();
        }
    }

    function _upsertExpectedBridge(
        PrefundedIntent storage intent,
        IOrderGatewayPrefund.ExpectedBridge calldata expectedBridge
    ) internal {
        if (intent.expectedBridgeId == bytes32(0)) {
            intent.expectedBridgeId = expectedBridge.bridgeId;
            intent.expectedBridgeType = uint8(expectedBridge.bridgeType);
            intent.expectedSrcDomain = expectedBridge.srcDomain;
            intent.expectedSrcSender = expectedBridge.srcSender;
            return;
        }

        if (
            intent.expectedBridgeId != expectedBridge.bridgeId ||
            intent.expectedBridgeType != uint8(expectedBridge.bridgeType) ||
            intent.expectedSrcDomain != expectedBridge.srcDomain ||
            intent.expectedSrcSender != expectedBridge.srcSender
        ) revert UnexpectedBridge();
    }

    function _destinationActionHash(
        Path calldata selectedPath,
        bytes calldata executorMessage
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(selectedPath.next, selectedPath.cur.message, executorMessage));
    }

    function _hasEnoughPrefundToExecute(PrefundedIntent storage intent) internal view returns (bool) {
        return IERC20(intent.prefundTerms.prefund.token).balanceOf(address(this)) >= intent.prefundTerms.prefund.amount;
    }

    function _storeExecutionData(
        PrefundedIntent storage intent,
        Path calldata selectedPath,
        SubmitterData calldata submitterData
    ) internal {
        intent.selectedPath.cur.executor = selectedPath.cur.executor;
        intent.selectedPath.cur.message = selectedPath.cur.message;
        intent.selectedPath.next = selectedPath.next;

        delete intent.submitterData.extraFunding;
        uint256 len = submitterData.extraFunding.length;
        for (uint256 i; i < len; ++i) {
            intent.submitterData.extraFunding.push(submitterData.extraFunding[i]);
        }
        intent.submitterData.executorMessage = submitterData.executorMessage;
    }

    function _pullExtraFundingToExecutorFromStorage(
        address funder,
        address executor,
        TokenAmount[] storage extraFunding
    ) internal {
        uint256 len = extraFunding.length;
        for (uint256 i; i < len; ++i) {
            IERC20(extraFunding[i].token).safeTransferFrom(funder, executor, extraFunding[i].amount);
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function setPermit2(address _permit2) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_permit2 == address(0)) revert InvalidAddress();
        permit2 = IPermit2(_permit2);
    }

    function setBridgeCaller(address caller, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isBridgeCaller[caller] = allowed;
    }

    function setTrustedSourceSender(uint32 srcDomain, bytes32 srcSender) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trustedSrcSenderByDomain[srcDomain] = srcSender;
    }

    // Legacy naming kept for convenience while migrating callers from OFT-specific terminology.
    function setTrustedSrcGateway(uint32 srcDomain, bytes32 srcSender) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trustedSrcSenderByDomain[srcDomain] = srcSender;
    }

    function computeIntentId(IntentKey calldata key, bytes32 orderHash) external pure returns (bytes32) {
        return OrderIdLib.intentId(key.srcChainId, key.srcGateway, key.user, orderHash, key.userSalt);
    }

    function getPrefundedIntent(bytes32 subOrderId) external view returns (PrefundedIntent memory) {
        return prefundedIntents[subOrderId];
    }

    function domainHash() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
