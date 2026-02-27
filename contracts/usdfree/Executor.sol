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

    struct ResolvedUserData {
        UserRequirements reqs;
        bool isAction;
        address target;
        bytes userAction;
        address recipient;
    }

    mapping(address => bool) public authorizedCaller;

    uint8 internal constant CHANGE_REQ_ID_TOKEN_REQ = 0;
    uint8 internal constant CHANGE_REQ_ID_USER_ACTION = 254;
    uint8 internal constant CHANGE_REQ_ID_APPEND_STATIC_REQ = 255;
    uint8 internal constant USER_DATA_TYPE_ACTION = uint8(UserDataType.RequirementsAndActionV1);
    uint8 internal constant USER_DATA_TYPE_SEND = uint8(UserDataType.RequirementsAndSendV1);

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
    error InvalidUserDataType();
    error InvalidForwarding();
    error InvalidRecipient();
    error DirectTransferFailed();
    error RequirementNotMet();
    error ExternalRequirementFailed();
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

        ResolvedUserData memory userData = _decodeUserData(stepAndNext.curStep.userData);

        if (stepAndNext.curStep.typ == GenericStepType.AuctionSubmitterUser) {
            _executeAuctionSubmitterUser(ctx, userData, stepAndNext.curStep.parts, submitterParts);
            return;
        }

        if (stepAndNext.curStep.typ == GenericStepType.SubmitterUser) {
            _executeSubmitterUser(ctx, userData, stepAndNext.curStep.parts, submitterParts);
            return;
        }

        if (stepAndNext.curStep.typ == GenericStepType.User) {
            _executeUser(ctx, userData, stepAndNext.curStep.parts, submitterParts);
            return;
        }

        revert InvalidStep();
    }

    function hashRequirementModifierResolution(
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
        ResolvedUserData memory userData,
        bytes[] calldata stepParts,
        bytes[] calldata submitterParts
    ) internal {
        if (stepParts.length != 1) revert InvalidStep();

        uint256 submitterCursor;
        RequirementModifierAction memory requirementModifierAction = abi.decode(
            stepParts[0],
            (RequirementModifierAction)
        );
        RequirementChange[] memory changes;

        (changes, submitterCursor) = _runAuctionSubstep(
            ctx,
            requirementModifierAction,
            submitterParts,
            submitterCursor
        );
        userData = _applyAuctionChanges(userData, changes);
        submitterCursor = _runSubmitterActionsSubstep(ctx, submitterParts, submitterCursor);
        (ForwardingAmounts memory forwarding, uint256 forwardingCursor) = _resolveForwarding(
            submitterParts,
            submitterCursor,
            userData.reqs.forwarding
        );
        _runUserRequirementAndActionSubstep(ctx, userData, forwarding);

        if (forwardingCursor != submitterParts.length) revert InvalidStep();
    }

    function _executeSubmitterUser(
        ExecutionContext memory ctx,
        ResolvedUserData memory userData,
        bytes[] calldata stepParts,
        bytes[] calldata submitterParts
    ) internal {
        if (stepParts.length != 0) revert InvalidStep();
        uint256 submitterCursor = _runSubmitterActionsSubstep(ctx, submitterParts, 0);
        (ForwardingAmounts memory forwarding, uint256 forwardingCursor) = _resolveForwarding(
            submitterParts,
            submitterCursor,
            userData.reqs.forwarding
        );
        _runUserRequirementAndActionSubstep(ctx, userData, forwarding);

        if (forwardingCursor != submitterParts.length) revert InvalidStep();
    }

    function _executeUser(
        ExecutionContext memory ctx,
        ResolvedUserData memory userData,
        bytes[] calldata stepParts,
        bytes[] calldata submitterParts
    ) internal {
        if (stepParts.length != 0 || submitterParts.length != 0) revert InvalidStep();
        _runUserRequirementAndActionSubstep(ctx, userData, userData.reqs.forwarding);
    }

    function _runAuctionSubstep(
        ExecutionContext memory ctx,
        RequirementModifierAction memory action,
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
        ResolvedUserData memory userData,
        ForwardingAmounts memory forwarding
    ) internal {
        (address requiredToken, uint256 requiredAmount) = _decodeTokenRequirement(userData.reqs.tokenReq);
        _checkForwarding(requiredToken, requiredAmount, forwarding);
        _checkStaticRequirements(ctx, userData.reqs.staticReqs);

        if (userData.isAction) {
            if (userData.target == address(0)) revert InvalidStep();

            if (requiredToken != address(0) && forwarding.erc20Amount != 0) {
                IERC20(requiredToken).forceApprove(userData.target, forwarding.erc20Amount);
            }

            IUserActionExecutor(userData.target).execute{ value: forwarding.nativeAmount }(
                requiredToken,
                forwarding.erc20Amount,
                ctx.orderId,
                userData.userAction,
                ctx.nextContinuation
            );

            if (requiredToken != address(0) && forwarding.erc20Amount != 0) {
                IERC20(requiredToken).forceApprove(userData.target, 0);
            }
            return;
        }

        if (userData.recipient == address(0)) revert InvalidRecipient();
        if (requiredToken != address(0) && forwarding.erc20Amount != 0) {
            IERC20(requiredToken).safeTransfer(userData.recipient, forwarding.erc20Amount);
        }
        if (forwarding.nativeAmount != 0) {
            (bool ok, ) = userData.recipient.call{ value: forwarding.nativeAmount }("");
            if (!ok) revert DirectTransferFailed();
        }
    }

    function _decodeUserData(TypedData calldata userData) internal pure returns (ResolvedUserData memory out) {
        if (userData.typ == USER_DATA_TYPE_ACTION) {
            UserRequirementsAndAction memory reqAction = abi.decode(userData.data, (UserRequirementsAndAction));
            out.reqs = reqAction.reqs;
            out.isAction = true;
            out.target = reqAction.target;
            out.userAction = reqAction.userAction;
            return out;
        }

        if (userData.typ == USER_DATA_TYPE_SEND) {
            UserRequirementsAndSend memory reqSend = abi.decode(userData.data, (UserRequirementsAndSend));
            out.reqs = reqSend.reqs;
            out.recipient = reqSend.recipient;
            return out;
        }

        revert InvalidUserDataType();
    }

    function _decodeTokenRequirement(TypedData memory tokenReq) internal pure returns (address token, uint256 amount) {
        if (tokenReq.typ != uint8(TokenRequirementType.MinAmount)) revert InvalidTokenRequirement();
        AmountTokenRequirement memory req = abi.decode(tokenReq.data, (AmountTokenRequirement));
        return (req.token, req.amount);
    }

    function _decodeForwarding(bytes calldata data) internal pure returns (ForwardingAmounts memory forwarding) {
        return abi.decode(data, (ForwardingAmounts));
    }

    function _resolveForwarding(
        bytes[] calldata submitterParts,
        uint256 submitterCursor,
        ForwardingAmounts memory fallbackForwarding
    ) internal pure returns (ForwardingAmounts memory forwarding, uint256 nextCursor) {
        if (submitterCursor >= submitterParts.length) return (fallbackForwarding, submitterCursor);
        return (_decodeForwarding(submitterParts[submitterCursor]), submitterCursor + 1);
    }

    function _checkForwarding(
        address requiredToken,
        uint256 requiredAmount,
        ForwardingAmounts memory forwarding
    ) internal view {
        uint256 requiredForwardedAmount = requiredToken == address(0)
            ? forwarding.nativeAmount
            : forwarding.erc20Amount;
        if (requiredForwardedAmount < requiredAmount) revert RequirementNotMet();
        if (requiredToken == address(0) && forwarding.erc20Amount != 0) revert InvalidForwarding();

        if (requiredToken != address(0) && _balanceOf(requiredToken) < forwarding.erc20Amount) {
            revert RequirementNotMet();
        }
        if (_balanceOf(address(0)) < forwarding.nativeAmount) revert RequirementNotMet();
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

    function _checkSubmitterRequirement(ExecutionContext memory ctx, bytes memory data) internal view {
        SubmitterRequirement memory req = abi.decode(data, (SubmitterRequirement));
        if (req.submitter != address(0) && req.submitter != ctx.submitter && block.timestamp <= req.exclusivityDeadline)
            revert RequirementNotMet();
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
        ResolvedUserData memory userData,
        RequirementChange[] memory changes
    ) internal pure returns (ResolvedUserData memory) {
        for (uint256 i = 0; i < changes.length; ++i) {
            RequirementChange memory change = changes[i];
            if (change.reqId == CHANGE_REQ_ID_TOKEN_REQ) {
                userData.reqs.tokenReq = _applyTokenReqChange(userData.reqs.tokenReq, change.change);
                continue;
            }

            if (change.reqId == CHANGE_REQ_ID_USER_ACTION) {
                if (!userData.isAction) revert InvalidAuctionChange();
                userData.userAction = abi.decode(change.change, (bytes));
                continue;
            }

            if (change.reqId == CHANGE_REQ_ID_APPEND_STATIC_REQ) {
                TypedData memory newReq = abi.decode(change.change, (TypedData));
                userData.reqs.staticReqs = _appendStaticReq(userData.reqs.staticReqs, newReq);
                continue;
            }

            uint256 staticIdx = uint256(change.reqId) - 1;
            if (staticIdx >= userData.reqs.staticReqs.length) revert InvalidAuctionChange();
            userData.reqs.staticReqs[staticIdx] = abi.decode(change.change, (TypedData));
        }

        return userData;
    }

    function _applyTokenReqChange(
        TypedData memory originalReq,
        bytes memory changeData
    ) internal pure returns (TypedData memory) {
        TypedData memory newReq = abi.decode(changeData, (TypedData));

        if (newReq.typ != uint8(TokenRequirementType.MinAmount)) revert InvalidTokenRequirement();

        if (originalReq.typ != uint8(TokenRequirementType.MinAmount)) revert InvalidTokenRequirement();

        AmountTokenRequirement memory orig = abi.decode(originalReq.data, (AmountTokenRequirement));
        AmountTokenRequirement memory next = abi.decode(newReq.data, (AmountTokenRequirement));

        if (orig.token != next.token || next.amount < orig.amount) revert InvalidAuctionChange();

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
            hashes[i] = keccak256(abi.encode(changes[i].reqId, keccak256(changes[i].change)));
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
        bytes32 digest = hashRequirementModifierResolution(ctx.orderId, ctx.tokenIn, ctx.amountIn, resolution.changes);
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
