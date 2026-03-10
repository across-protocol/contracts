// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "./Interfaces.sol";

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts-v4/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts-v4/security/ReentrancyGuard.sol";

contract OrderStore is Ownable, ReentrancyGuard, IOrderStore {
    using SafeERC20 for IERC20;

    struct StoredOrder {
        address user;
        address token;
        uint256 amount;
        bytes32 orderId;
        RefundConfig refundConfig;
        bytes continuation;
        bool filled;
        bool refunded;
    }

    IExecutor public immutable executor;
    StoredOrder[] public storedOrders;

    event OrderStored(uint256 indexed localOrderIndex, bytes32 indexed orderId, address token, uint256 amount);
    event OrderFilled(uint256 indexed localOrderIndex, bytes32 indexed orderId, address submitter);
    event OrderRefundedByUser(uint256 indexed localOrderIndex, bytes32 indexed orderId, address recipient);
    event OrderRefundedByAdmin(uint256 indexed localOrderIndex, bytes32 indexed orderId, address recipient);

    error InvalidFunding();
    error InvalidStoredOrder();
    error InvalidDeobfuscation();
    error MissingDeobfuscationPart();
    error InvalidContinuation();
    error UnauthorizedRefund();
    error RefundExpired();
    error RefundTransferFailed();

    constructor(address _executor) Ownable() {
        executor = IExecutor(_executor);
    }

    function handle(
        address token,
        uint256 amount,
        bytes32 orderId,
        bytes calldata continuation
    ) external payable override nonReentrant {
        _validateUserMsgValue(token, amount);
        uint256 received = _pullToken(msg.sender, token, amount);
        RefundConfig memory refundConfig = _extractRefundConfig(continuation);

        uint256 localOrderIndex = storedOrders.length;
        storedOrders.push(
            StoredOrder({
                user: msg.sender,
                token: token,
                amount: received,
                orderId: orderId,
                refundConfig: refundConfig,
                continuation: continuation,
                filled: false,
                refunded: false
            })
        );

        emit OrderStored(localOrderIndex, orderId, token, received);
    }

    function handleAtomic(
        address token,
        uint256 amount,
        bytes32 orderId,
        bytes calldata continuation,
        address submitter,
        SubmitterData calldata submitterData
    ) external payable override nonReentrant {
        uint256 userNativeAmount = token == address(0) ? amount : 0;
        if (msg.value < userNativeAmount) revert InvalidFunding();
        uint256 submitterNativeAmount = msg.value - userNativeAmount;
        uint256 received = _pullToken(msg.sender, token, amount);
        _execute(token, received, orderId, continuation, submitter, submitterData, submitterNativeAmount);
    }

    function fill(
        uint256 localOrderIndex,
        SubmitterData calldata submitterData
    ) external payable override nonReentrant {
        if (localOrderIndex >= storedOrders.length) revert InvalidStoredOrder();

        StoredOrder storage order = storedOrders[localOrderIndex];
        if (order.filled || order.refunded) revert InvalidStoredOrder();
        order.filled = true;

        uint256 submitterNativeAmount = msg.value;

        _execute(
            order.token,
            order.amount,
            order.orderId,
            order.continuation,
            msg.sender,
            submitterData,
            submitterNativeAmount
        );

        emit OrderFilled(localOrderIndex, order.orderId, msg.sender);
    }

    function refundByUser(uint256 localOrderIndex) external override nonReentrant {
        if (localOrderIndex >= storedOrders.length) revert InvalidStoredOrder();

        StoredOrder storage order = storedOrders[localOrderIndex];
        if (order.filled || order.refunded) revert InvalidStoredOrder();
        if (msg.sender != order.user) revert UnauthorizedRefund();
        if (order.refundConfig.reverseDeadline != 0 && block.timestamp > order.refundConfig.reverseDeadline) {
            revert RefundExpired();
        }

        order.refunded = true;
        address recipient = order.refundConfig.refundRecipient == address(0)
            ? order.user
            : order.refundConfig.refundRecipient;
        _refund(order.token, order.amount, recipient);
        emit OrderRefundedByUser(localOrderIndex, order.orderId, recipient);
    }

    function refundByAdmin(uint256 localOrderIndex) external override onlyOwner nonReentrant {
        if (localOrderIndex >= storedOrders.length) revert InvalidStoredOrder();

        StoredOrder storage order = storedOrders[localOrderIndex];
        if (order.filled || order.refunded) revert InvalidStoredOrder();
        if (order.refundConfig.reverseDeadline != 0 && block.timestamp > order.refundConfig.reverseDeadline) {
            revert RefundExpired();
        }

        order.refunded = true;
        _refund(order.token, order.amount, owner());
        emit OrderRefundedByAdmin(localOrderIndex, order.orderId, owner());
    }

    function _execute(
        address token,
        uint256 amount,
        bytes32 orderId,
        bytes memory continuation,
        address submitter,
        SubmitterData calldata submitterData,
        uint256 submitterNativeAmount
    ) internal {
        (StepAndNext memory stepAndNext, uint256 consumedParts) = _resolveStepAndNext(
            continuation,
            submitterData.parts
        );

        bytes[] memory submitterParts = _sliceParts(submitterData.parts, consumedParts);
        _pullExtraFunding(submitter, submitterData.extraErc20Funding);

        uint256 amountIn = token == address(0) ? amount : _sendLocalTokenToExecutor(token, amount);

        executor.execute{ value: (token == address(0) ? amountIn : 0) + submitterNativeAmount }(
            submitter,
            orderId,
            token,
            amountIn,
            submitterNativeAmount,
            submitterParts,
            stepAndNext
        );
    }

    function _resolveStepAndNext(
        bytes memory continuationBytes,
        bytes[] calldata submitterParts
    ) internal pure returns (StepAndNext memory stepAndNext, uint256 consumedParts) {
        Continuation memory continuation = abi.decode(continuationBytes, (Continuation));

        if (continuation.typ == ContinuationType.StepAndNextHash) {
            if (submitterParts.length == 0) revert MissingDeobfuscationPart();

            bytes32 expectedHash = abi.decode(continuation.data, (bytes32));
            stepAndNext = abi.decode(submitterParts[0], (StepAndNext));
            if (keccak256(abi.encode(stepAndNext)) != expectedHash) revert InvalidDeobfuscation();
            return (stepAndNext, 1);
        }

        if (continuation.typ == ContinuationType.StepAndNextData) {
            stepAndNext = abi.decode(continuation.data, (StepAndNext));
            return (stepAndNext, 0);
        }

        if (continuation.typ == ContinuationType.GenericSteps) {
            GenericStep[] memory allSteps = abi.decode(continuation.data, (GenericStep[]));
            if (allSteps.length == 0) revert InvalidDeobfuscation();

            bytes memory remainingData;
            if (allSteps.length == 1) {
                remainingData = abi.encode(new GenericStep[](0));
            } else {
                GenericStep[] memory tail = new GenericStep[](allSteps.length - 1);
                for (uint256 i = 1; i < allSteps.length; ++i) tail[i - 1] = allSteps[i];
                remainingData = abi.encode(tail);
            }

            stepAndNext = StepAndNext({
                curStep: allSteps[0],
                nextContinuation: abi.encode(Continuation({ typ: ContinuationType.GenericSteps, data: remainingData }))
            });

            return (stepAndNext, 0);
        }

        revert InvalidContinuation();
    }

    function _extractRefundConfig(bytes calldata continuationBytes) internal pure returns (RefundConfig memory config) {
        Continuation memory continuation = abi.decode(continuationBytes, (Continuation));

        if (continuation.typ == ContinuationType.StepAndNextData) {
            StepAndNext memory stepAndNext = abi.decode(continuation.data, (StepAndNext));
            return stepAndNext.curStep.refundConfig;
        }

        if (continuation.typ == ContinuationType.GenericSteps) {
            GenericStep[] memory allSteps = abi.decode(continuation.data, (GenericStep[]));
            if (allSteps.length == 0) revert InvalidDeobfuscation();
            return allSteps[0].refundConfig;
        }

        // StepAndNextHash cannot expose refund metadata at storage time.
        revert InvalidContinuation();
    }

    function _sliceParts(bytes[] calldata parts, uint256 start) internal pure returns (bytes[] memory sliced) {
        if (start == 0) {
            sliced = new bytes[](parts.length);
            for (uint256 i = 0; i < parts.length; ++i) sliced[i] = parts[i];
            return sliced;
        }

        if (start > parts.length) revert InvalidDeobfuscation();
        sliced = new bytes[](parts.length - start);
        for (uint256 i = start; i < parts.length; ++i) sliced[i - start] = parts[i];
    }

    function _pullToken(address from, address token, uint256 amount) internal returns (uint256 received) {
        if (token == address(0)) {
            return amount;
        }

        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        return IERC20(token).balanceOf(address(this)) - beforeBal;
    }

    function _sendLocalTokenToExecutor(address token, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBal = IERC20(token).balanceOf(address(executor));
        IERC20(token).safeTransfer(address(executor), amount);
        return IERC20(token).balanceOf(address(executor)) - beforeBal;
    }

    function _pullExtraFunding(address submitter, TokenAmount[] calldata extraErc20Funding) internal {
        for (uint256 i = 0; i < extraErc20Funding.length; ++i) {
            TokenAmount calldata funding = extraErc20Funding[i];
            if (funding.token == address(0)) revert InvalidFunding();
            uint256 pulled = _pullToken(submitter, funding.token, funding.amount);
            uint256 received = _sendLocalTokenToExecutor(funding.token, pulled);
            if (funding.amount != 0 && received == 0) {
                revert InvalidFunding();
            }
        }
    }

    function _validateUserMsgValue(address token, uint256 amount) internal view {
        uint256 expectedUserNative = token == address(0) ? amount : 0;
        if (msg.value != expectedUserNative) revert InvalidFunding();
    }

    function _refund(address token, uint256 amount, address recipient) internal {
        if (token == address(0)) {
            (bool success, ) = recipient.call{ value: amount }("");
            if (!success) revert RefundTransferFailed();
            return;
        }
        IERC20(token).safeTransfer(recipient, amount);
    }
}
