// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "./Interfaces.sol";

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import { SignatureChecker } from "@openzeppelin/contracts-v4/utils/cryptography/SignatureChecker.sol";
import { Ownable } from "@openzeppelin/contracts-v4/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts-v4/security/ReentrancyGuard.sol";

contract Executor is Ownable, ReentrancyGuard, IExecutor {
    using SafeERC20 for IERC20;

    struct ExecutionContext {
        address submitter;
        bytes32 orderId;
        address tokenIn;
        uint256 amountIn;
        bytes nextContinuation;
    }

    mapping(address => bool) public authorizedCaller;

    uint8 internal constant CHANGE_REQ_ID_TOKEN_REQ = 0;
    uint8 internal constant CHANGE_REQ_ID_USER_ACTION = 254;
    uint8 internal constant CHANGE_REQ_ID_APPEND_STATIC_REQ = 255;

    event AuthorizedCallerSet(address indexed caller, bool enabled);

    error UnauthorizedCaller();
    error InvalidStep();
    error InvalidTokenRequirement();
    error InvalidStaticRequirement();
    error UnsupportedAuctionType();
    error InvalidAuctionAuthority();
    error AuctionExpired();
    error InvalidAuctionSignature();
    error MissingSubmitterPart();
    error UnsupportedSubmitterActionType();
    error UnsupportedTransferType();
    error RequirementNotMet();
    error ExternalRequirementFailed();
    error UnsupportedAuctionChange();
    error InvalidAuctionChange();
    error SubmitterActionCallFailed(uint256 index);
    error InvalidSubmitterActionCall(uint256 index);

    modifier onlyAuthorizedCaller() {
        if (!authorizedCaller[msg.sender]) revert UnauthorizedCaller();
        _;
    }

    constructor() Ownable() {}

    function setAuthorizedCaller(address caller, bool enabled) external onlyOwner {
        authorizedCaller[caller] = enabled;
        emit AuthorizedCallerSet(caller, enabled);
    }

    function execute(
        address submitter,
        bytes32 orderId,
        address userTokenIn,
        uint256 userAmountIn,
        uint256 submitterNativeAmount,
        bytes[] calldata submitterParts,
        StepAndNext calldata stepAndNext
    ) external payable override nonReentrant onlyAuthorizedCaller {
        uint256 expectedMsgValue = (userTokenIn == address(0) ? userAmountIn : 0) + submitterNativeAmount;
        if (msg.value != expectedMsgValue) revert InvalidStep();

        ExecutionContext memory ctx = ExecutionContext({
            submitter: submitter,
            orderId: orderId,
            tokenIn: userTokenIn,
            amountIn: userAmountIn,
            nextContinuation: stepAndNext.nextContinuation
        });

        if (stepAndNext.curStep.typ == GenericStepType.AuctionSubmitterUser) {
            _executeAuctionSubmitterUser(ctx, stepAndNext.curStep.parts, submitterParts);
            return;
        }

        if (stepAndNext.curStep.typ == GenericStepType.SubmitterUser) {
            _executeSubmitterUser(ctx, stepAndNext.curStep.parts, submitterParts);
            return;
        }

        if (stepAndNext.curStep.typ == GenericStepType.User) {
            _executeUser(ctx, stepAndNext.curStep.parts, submitterParts);
            return;
        }

        revert InvalidStep();
    }

    function hashAuctionResolution(
        bytes32 orderId,
        address tokenIn,
        uint256 amountIn,
        RequirementChange[] memory changes
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(block.chainid, address(this), orderId, tokenIn, amountIn, _hashRequirementChanges(changes))
            );
    }

    function _executeAuctionSubmitterUser(
        ExecutionContext memory ctx,
        bytes[] calldata userParts,
        bytes[] calldata submitterParts
    ) internal {
        if (userParts.length != 2) revert InvalidStep();

        uint256 submitterCursor;
        AuctionAction memory auctionAction = abi.decode(userParts[0], (AuctionAction));
        UserRequirementsAndAction memory reqAction = abi.decode(userParts[1], (UserRequirementsAndAction));
        RequirementChange[] memory changes;

        (changes, submitterCursor) = _runAuctionSubstep(ctx, auctionAction, submitterParts, submitterCursor);
        reqAction = _applyAuctionChanges(reqAction, changes);
        submitterCursor = _runSubmitterActionsSubstep(ctx, submitterParts, submitterCursor);
        _runUserRequirementAndActionSubstep(ctx, reqAction);

        if (submitterCursor != submitterParts.length) revert InvalidStep();
    }

    function _executeSubmitterUser(
        ExecutionContext memory ctx,
        bytes[] calldata userParts,
        bytes[] calldata submitterParts
    ) internal {
        if (userParts.length != 1) revert InvalidStep();

        UserRequirementsAndAction memory reqAction = abi.decode(userParts[0], (UserRequirementsAndAction));
        uint256 submitterCursor = _runSubmitterActionsSubstep(ctx, submitterParts, 0);
        _runUserRequirementAndActionSubstep(ctx, reqAction);

        if (submitterCursor != submitterParts.length) revert InvalidStep();
    }

    function _executeUser(
        ExecutionContext memory ctx,
        bytes[] calldata userParts,
        bytes[] calldata submitterParts
    ) internal {
        if (userParts.length != 1 || submitterParts.length != 0) revert InvalidStep();
        UserRequirementsAndAction memory reqAction = abi.decode(userParts[0], (UserRequirementsAndAction));
        _runUserRequirementAndActionSubstep(ctx, reqAction);
    }

    function _runAuctionSubstep(
        ExecutionContext memory ctx,
        AuctionAction memory action,
        bytes[] calldata submitterParts,
        uint256 submitterCursor
    ) internal view returns (RequirementChange[] memory changes, uint256 newSubmitterCursor) {
        if (action.typ == AuctionType.Offchain) {
            (changes, submitterCursor) = _getOffchainAuctionChanges(ctx, action.data, submitterParts, submitterCursor);
        } else {
            revert UnsupportedAuctionType();
        }
        return (changes, submitterCursor);
    }

    function _runSubmitterActionsSubstep(
        ExecutionContext memory ctx,
        bytes[] calldata submitterParts,
        uint256 submitterCursor
    ) internal returns (uint256) {
        if (submitterCursor >= submitterParts.length) revert MissingSubmitterPart();

        SubmitterActions memory actions = abi.decode(submitterParts[submitterCursor], (SubmitterActions));
        submitterCursor++;

        if (actions.typ == SubmitterActionType.None) return submitterCursor;
        if (actions.typ == SubmitterActionType.MulticallHandler) {
            _executeMulticallSubmitterActions(actions.data);
            return submitterCursor;
        }
        if (actions.typ == SubmitterActionType.Weiroll) {
            _executeWeirollSubmitterActions(ctx, actions.data);
            return submitterCursor;
        }

        revert UnsupportedSubmitterActionType();
    }

    function _executeMulticallSubmitterActions(bytes memory data) internal {
        ExecutorCall[] memory calls = abi.decode(data, (ExecutorCall[]));
        _attemptCalls(calls);
    }

    function _executeWeirollSubmitterActions(ExecutionContext memory, bytes memory) internal pure {
        // TODO: add Weiroll support.
        revert UnsupportedSubmitterActionType();
    }

    function _runUserRequirementAndActionSubstep(
        ExecutionContext memory ctx,
        UserRequirementsAndAction memory reqAction
    ) internal {
        if (reqAction.target == address(0)) revert InvalidStep();

        (address outToken, uint256 outAmount) = _checkTokenRequirement(reqAction.tokenReq);
        _checkStaticRequirements(ctx, reqAction.staticReqs);

        uint8 transferType = reqAction.transfer.typ;
        if (transferType == uint8(TransferType.Approval)) {
            if (outToken == address(0)) revert UnsupportedTransferType();
            IERC20(outToken).forceApprove(reqAction.target, outAmount);
        } else if (transferType == uint8(TransferType.Transfer)) {
            if (outToken != address(0)) IERC20(outToken).safeTransfer(reqAction.target, outAmount);
        } else {
            revert UnsupportedTransferType();
        }

        IUserActionExecutor(reqAction.target).execute{ value: outToken == address(0) ? outAmount : 0 }(
            outToken,
            outAmount,
            ctx.orderId,
            reqAction.userAction,
            ctx.nextContinuation
        );

        if (transferType == uint8(TransferType.Approval) && outToken != address(0)) {
            IERC20(outToken).forceApprove(reqAction.target, 0);
        }
    }

    function _checkTokenRequirement(TypedData memory tokenReq) internal view returns (address token, uint256 amount) {
        if (
            tokenReq.typ != uint8(TokenRequirementType.StrictAmount) &&
            tokenReq.typ != uint8(TokenRequirementType.MinAmount)
        ) revert InvalidTokenRequirement();

        AmountTokenRequirement memory req = abi.decode(tokenReq.data, (AmountTokenRequirement));
        amount = _balanceOf(req.token);

        if (tokenReq.typ == uint8(TokenRequirementType.StrictAmount) && amount != req.amount)
            revert RequirementNotMet();
        if (tokenReq.typ == uint8(TokenRequirementType.MinAmount) && amount < req.amount) revert RequirementNotMet();

        return (req.token, amount);
    }

    function _checkStaticRequirements(ExecutionContext memory ctx, TypedData[] memory reqs) internal view {
        uint256 length = reqs.length;
        for (uint256 i = 0; i < length; ++i) {
            if (reqs[i].typ == uint8(StaticRequirementType.Submitter)) {
                _checkSubmitterRequirement(ctx, reqs[i].data);
                continue;
            }

            if (reqs[i].typ == uint8(StaticRequirementType.Deadline)) {
                _checkDeadlineRequirement(reqs[i].data);
                continue;
            }

            if (reqs[i].typ == uint8(StaticRequirementType.ExternalStaticCall)) {
                _checkExternalStaticCallRequirement(reqs[i].data);
                continue;
            }

            revert InvalidStaticRequirement();
        }
    }

    function _checkSubmitterRequirement(ExecutionContext memory ctx, bytes memory data) internal pure {
        SubmitterRequirement memory req = abi.decode(data, (SubmitterRequirement));
        if (req.submitter != address(0) && req.submitter != ctx.submitter) revert RequirementNotMet();
    }

    function _checkDeadlineRequirement(bytes memory data) internal view {
        DeadlineRequirement memory req = abi.decode(data, (DeadlineRequirement));
        if (req.deadline != 0 && block.timestamp > req.deadline) revert RequirementNotMet();
    }

    function _checkExternalStaticCallRequirement(bytes memory data) internal view {
        ExternalStaticCallRequirement memory req = abi.decode(data, (ExternalStaticCallRequirement));
        (bool ok, bytes memory returnData) = req.target.staticcall(req.data);
        if (!ok) revert ExternalRequirementFailed();
        if (req.expectedResultHash != bytes32(0) && keccak256(returnData) != req.expectedResultHash) {
            revert RequirementNotMet();
        }
    }

    function _applyAuctionChanges(
        UserRequirementsAndAction memory reqAction,
        RequirementChange[] memory changes
    ) internal pure returns (UserRequirementsAndAction memory) {
        for (uint256 i = 0; i < changes.length; ++i) {
            RequirementChange memory change = changes[i];
            if (change.stepOffset != 0) revert UnsupportedAuctionChange();

            if (change.reqId == CHANGE_REQ_ID_TOKEN_REQ) {
                reqAction.tokenReq = _applyTokenReqChange(reqAction.tokenReq, change.change);
                continue;
            }

            if (change.reqId == CHANGE_REQ_ID_USER_ACTION) {
                reqAction.userAction = abi.decode(change.change, (bytes));
                continue;
            }

            if (change.reqId == CHANGE_REQ_ID_APPEND_STATIC_REQ) {
                TypedData memory newReq = abi.decode(change.change, (TypedData));
                reqAction.staticReqs = _appendStaticReq(reqAction.staticReqs, newReq);
                continue;
            }

            uint256 staticIdx = uint256(change.reqId) - 1;
            if (staticIdx >= reqAction.staticReqs.length) revert InvalidAuctionChange();
            reqAction.staticReqs[staticIdx] = abi.decode(change.change, (TypedData));
        }

        return reqAction;
    }

    function _applyTokenReqChange(
        TypedData memory originalReq,
        bytes memory changeData
    ) internal pure returns (TypedData memory) {
        TypedData memory newReq = abi.decode(changeData, (TypedData));

        if (
            newReq.typ != uint8(TokenRequirementType.StrictAmount) &&
            newReq.typ != uint8(TokenRequirementType.MinAmount)
        ) revert InvalidTokenRequirement();

        if (
            originalReq.typ != uint8(TokenRequirementType.StrictAmount) &&
            originalReq.typ != uint8(TokenRequirementType.MinAmount)
        ) revert InvalidTokenRequirement();

        AmountTokenRequirement memory orig = abi.decode(originalReq.data, (AmountTokenRequirement));
        AmountTokenRequirement memory next = abi.decode(newReq.data, (AmountTokenRequirement));

        if (orig.token != next.token || next.amount < orig.amount) revert InvalidAuctionChange();
        if (
            originalReq.typ == uint8(TokenRequirementType.StrictAmount) &&
            newReq.typ != uint8(TokenRequirementType.StrictAmount)
        ) {
            revert InvalidAuctionChange();
        }

        return newReq;
    }

    function _appendStaticReq(
        TypedData[] memory reqs,
        TypedData memory newReq
    ) internal pure returns (TypedData[] memory out) {
        out = new TypedData[](reqs.length + 1);
        for (uint256 i = 0; i < reqs.length; ++i) out[i] = reqs[i];
        out[reqs.length] = newReq;
    }

    function _balanceOf(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _hashRequirementChanges(RequirementChange[] memory changes) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](changes.length);
        for (uint256 i = 0; i < changes.length; ++i) {
            hashes[i] = keccak256(abi.encode(changes[i].stepOffset, changes[i].reqId, keccak256(changes[i].change)));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _getOffchainAuctionChanges(
        ExecutionContext memory ctx,
        bytes memory auctionData,
        bytes[] calldata submitterParts,
        uint256 submitterCursor
    ) internal view returns (RequirementChange[] memory changes, uint256 newSubmitterCursor) {
        if (submitterCursor >= submitterParts.length) revert MissingSubmitterPart();

        OffchainAuctionConfig memory config = abi.decode(auctionData, (OffchainAuctionConfig));
        if (config.authority == address(0)) revert InvalidAuctionAuthority();
        if (config.deadline != 0 && block.timestamp > config.deadline) revert AuctionExpired();

        AuctionResolution memory resolution = abi.decode(submitterParts[submitterCursor], (AuctionResolution));
        bytes32 digest = hashAuctionResolution(ctx.orderId, ctx.tokenIn, ctx.amountIn, resolution.changes);
        if (!SignatureChecker.isValidSignatureNow(config.authority, digest, resolution.sig)) {
            revert InvalidAuctionSignature();
        }

        return (resolution.changes, submitterCursor + 1);
    }

    function _attemptCalls(ExecutorCall[] memory calls) internal {
        uint256 length = calls.length;
        for (uint256 i = 0; i < length; ++i) {
            ExecutorCall memory current = calls[i];

            if (current.callData.length > 0 && current.target.code.length == 0) {
                revert InvalidSubmitterActionCall(i);
            }

            (bool success, ) = current.target.call{ value: current.value }(current.callData);
            if (!success) revert SubmitterActionCallFailed(i);
        }
    }

    receive() external payable {}
}
