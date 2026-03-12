// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {
    Order,
    Path,
    TokenAmount,
    TypedData,
    SubmitterData,
    IOrderGateway,
    OrderFundingType,
    DirectTransferFunding,
    PrefundTerms,
    BridgeType
} from "./Interfaces.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AccessControlDefaultAdminRules } from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ILayerZeroComposer } from "../external/interfaces/ILayerZeroComposer.sol";
import { OFTComposeMsgCodec } from "../external/libraries/OFTComposeMsgCodec.sol";

contract OFTDstHandler is ReentrancyGuard, AccessControlDefaultAdminRules, ILayerZeroComposer {
    using SafeERC20 for IERC20;

    enum PrefundStatus {
        None,
        Prefunded,
        ExecutedPendingBridge,
        BridgeArrived,
        Executed,
        Refunded
    }

    struct ExpectedBridge {
        BridgeType bridgeType;
        bytes32 bridgeId;
        uint32 srcDomain;
        bytes32 srcSender;
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
        uint256 prefundDeposited;
        uint256 bridgedDeposited;
        Order order;
        Path selectedPath;
        bytes32[] pathProof;
        SubmitterData submitterData;
        PrefundStatus status;
    }

    // Compose message payload for LZ compose calls.
    struct ComposePayload {
        bytes32 subOrderId;
        PrefundTerms prefundTerms;
    }

    IOrderGateway public orderGateway;
    address public immutable OFT_ENDPOINT_ADDRESS;
    address public immutable IOFT_ADDRESS;
    address public immutable baseToken;

    mapping(bytes32 => PrefundedIntent) internal prefundedIntents;
    mapping(bytes32 => bytes32) public bridgeIdToSubOrderId;
    mapping(uint32 => bytes32) public authorizedSrcPeriphery;

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
        uint32 srcEid,
        address token,
        uint256 amount
    );

    event PrefundedOrderSettled(bytes32 indexed subOrderId, address reimbursementToken, uint256 reimbursementAmount);

    error InvalidSubOrder();
    error SubOrderAlreadyProcessed();
    error InvalidState();
    error InvalidPrefundAmount();
    error InvalidBridgeToken();
    error MinReimbursementNotMet();
    error InsufficientBridgeFunds();
    error InvalidActionHash();
    error InvalidSubOrderId();
    error InvalidAddress();
    error InvalidOApp();
    error UnauthorizedEndpoint();
    error AuthorizedPeripheryNotSet(uint32 srcEid);
    error UnauthorizedSrcPeriphery(uint32 srcEid);
    error DuplicateBridgeId();
    error RefundNotReady();

    constructor(
        address _owner,
        address _orderGateway,
        address _oftEndpoint,
        address _ioftAddress,
        address _baseToken
    ) AccessControlDefaultAdminRules(0, _owner) {
        orderGateway = IOrderGateway(_orderGateway);
        OFT_ENDPOINT_ADDRESS = _oftEndpoint;
        IOFT_ADDRESS = _ioftAddress;
        baseToken = _baseToken;
    }

    function prefund(
        bytes32 subOrderId,
        bytes32 orderRoot,
        ExpectedBridge calldata expectedBridge,
        Order calldata order,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        SubmitterData calldata submitterData,
        PrefundTerms calldata prefundTerms,
        address refundTo
    ) external payable nonReentrant {
        if (order.root != orderRoot) revert InvalidSubOrder();
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
        intent.prefundDeposited = prefundTerms.prefund.amount;

        // Pull extra funding upfront into this contract.
        for (uint256 i; i < submitterData.extraFunding.length; ++i) {
            IERC20(submitterData.extraFunding[i].token).safeTransferFrom(
                msg.sender,
                address(this),
                submitterData.extraFunding[i].amount
            );
        }

        intent.refundTo = refundTo;
        intent.executionSubmitter = msg.sender;
        intent.executionNativeValue = msg.value;
        _storeExecutionData(intent, order, selectedPath, pathProof, submitterData);

        if (intent.status == PrefundStatus.BridgeArrived) {
            _completeOrder(subOrderId, intent);
            _settleBridgeToSubmitter(subOrderId, intent);
        } else {
            intent.status = PrefundStatus.Prefunded;
        }

        emit Prefunded(subOrderId, msg.sender, prefundTerms.prefund.token, prefundTerms.prefund.amount, orderRoot);
    }

    function lzCompose(
        address _oApp,
        bytes32 /* _guid */,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) external payable override nonReentrant {
        _requireAuthorizedMessage(_oApp, _message);

        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
        bytes memory composeMsgBytes = OFTComposeMsgCodec.composeMsg(_message);
        ComposePayload memory payload = abi.decode(composeMsgBytes, (ComposePayload));

        bytes32 subOrderId = payload.subOrderId;
        PrefundedIntent storage intent = prefundedIntents[subOrderId];

        if (intent.status == PrefundStatus.Executed || intent.status == PrefundStatus.Refunded)
            revert SubOrderAlreadyProcessed();

        _upsertIntentCommitment(intent, bytes32(0), bytes32(0), payload.prefundTerms);
        intent.bridgedDeposited = amountLD;

        if (intent.status == PrefundStatus.Prefunded) {
            _completeOrder(subOrderId, intent);
            _settleBridgeToSubmitter(subOrderId, intent);
        } else if (intent.status == PrefundStatus.ExecutedPendingBridge) {
            _settleBridgeToSubmitter(subOrderId, intent);
        } else {
            // Bridge arrived first, no prefund yet.
            intent.status = PrefundStatus.BridgeArrived;
        }

        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
        emit BridgeMessageArrived(subOrderId, bytes32(0), srcEid, baseToken, amountLD);
    }

    function refundPrefund(bytes32 subOrderId) external nonReentrant {
        PrefundedIntent storage intent = prefundedIntents[subOrderId];
        if (intent.status != PrefundStatus.Prefunded && intent.status != PrefundStatus.BridgeArrived)
            revert InvalidState();
        if (intent.prefundTerms.expiry == 0 || block.timestamp <= intent.prefundTerms.expiry) revert RefundNotReady();

        if (intent.prefundDeposited > 0 && intent.prefundTerms.prefund.token != address(0)) {
            IERC20(intent.prefundTerms.prefund.token).safeTransfer(intent.refundTo, intent.prefundDeposited);
        }
        // Refund extra funding.
        SubmitterData storage sd = intent.submitterData;
        for (uint256 i; i < sd.extraFunding.length; ++i) {
            if (sd.extraFunding[i].amount > 0) {
                IERC20(sd.extraFunding[i].token).safeTransfer(intent.refundTo, sd.extraFunding[i].amount);
            }
        }
        intent.status = PrefundStatus.Refunded;
    }

    // --- Internal: order completion ---

    function _completeOrder(bytes32 subOrderId, PrefundedIntent storage intent) internal {
        Order memory order = intent.order;
        Path memory selectedPath = intent.selectedPath;
        bytes32[] memory proof = intent.pathProof;
        SubmitterData memory sd = intent.submitterData;

        // Approve orderGateway to pull prefund tokens.
        IERC20(intent.prefundTerms.prefund.token).forceApprove(address(orderGateway), intent.prefundDeposited);

        // Approve orderGateway to pull extra funding.
        for (uint256 i; i < sd.extraFunding.length; ++i) {
            IERC20(sd.extraFunding[i].token).forceApprove(address(orderGateway), sd.extraFunding[i].amount);
        }

        // Build DirectTransferFunding.
        bytes32 salt = keccak256(abi.encode(subOrderId));
        TypedData memory funding = TypedData({
            typ: uint8(OrderFundingType.DirectTransfer),
            data: abi.encode(DirectTransferFunding({ tokenAmount: intent.prefundTerms.prefund, salt: salt }))
        });

        orderGateway.submitWithData{ value: intent.executionNativeValue }(order, selectedPath, proof, funding, sd);
        intent.status = PrefundStatus.ExecutedPendingBridge;
    }

    function _settleBridgeToSubmitter(bytes32 subOrderId, PrefundedIntent storage intent) internal {
        if (intent.prefundTerms.minReimbursement.token != baseToken) revert InvalidBridgeToken();
        if (intent.bridgedDeposited < intent.prefundTerms.minReimbursement.amount) revert MinReimbursementNotMet();

        IERC20(baseToken).safeTransfer(intent.refundTo, intent.bridgedDeposited);
        intent.status = PrefundStatus.Executed;

        emit PrefundedOrderSettled(subOrderId, baseToken, intent.bridgedDeposited);
    }

    // --- Internal: LZ authorization ---

    function _requireAuthorizedMessage(address _oApp, bytes calldata _message) internal view {
        if (_oApp != IOFT_ADDRESS) revert InvalidOApp();
        if (msg.sender != OFT_ENDPOINT_ADDRESS) revert UnauthorizedEndpoint();

        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
        bytes32 authorized = authorizedSrcPeriphery[srcEid];
        if (authorized == bytes32(0)) revert AuthorizedPeripheryNotSet(srcEid);
        bytes32 composeFrom = OFTComposeMsgCodec.composeFrom(_message);
        if (authorized != composeFrom) revert UnauthorizedSrcPeriphery(srcEid);
    }

    // --- Internal: intent state helpers ---

    function _upsertIntentCommitment(
        PrefundedIntent storage intent,
        bytes32 orderRoot,
        bytes32 dstActionHash,
        PrefundTerms memory prefundTerms
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

    function _upsertExpectedBridge(PrefundedIntent storage intent, ExpectedBridge calldata expectedBridge) internal {
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
        ) revert InvalidSubOrderId();
    }

    function _destinationActionHash(
        Path calldata selectedPath,
        bytes calldata executorMessage
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(selectedPath.next, selectedPath.cur.message, executorMessage));
    }

    function _storeExecutionData(
        PrefundedIntent storage intent,
        Order calldata order,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        SubmitterData calldata submitterData
    ) internal {
        intent.order = order;
        intent.selectedPath.cur.executor = selectedPath.cur.executor;
        intent.selectedPath.cur.message = selectedPath.cur.message;
        intent.selectedPath.next = selectedPath.next;

        delete intent.pathProof;
        for (uint256 i; i < pathProof.length; ++i) {
            intent.pathProof.push(pathProof[i]);
        }

        delete intent.submitterData.extraFunding;
        for (uint256 i; i < submitterData.extraFunding.length; ++i) {
            intent.submitterData.extraFunding.push(submitterData.extraFunding[i]);
        }
        intent.submitterData.executorMessage = submitterData.executorMessage;
    }

    // --- Admin ---

    function setAuthorizedPeriphery(uint32 srcEid, bytes32 srcPeriphery) external onlyRole(DEFAULT_ADMIN_ROLE) {
        authorizedSrcPeriphery[srcEid] = srcPeriphery;
    }

    function setOrderGateway(address _orderGateway) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_orderGateway == address(0)) revert InvalidAddress();
        orderGateway = IOrderGateway(_orderGateway);
    }

    // --- View ---

    function getPrefundedIntent(bytes32 subOrderId) external view returns (PrefundedIntent memory) {
        return prefundedIntents[subOrderId];
    }
}
