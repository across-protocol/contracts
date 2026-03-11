// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { AbstractMulticallExecutor } from "./AbstractMulticallExecutor.sol";
import { IExecutor, IUserActionExecutor, Path, TokenAmount } from "./Interfaces.sol";
import { ExecutorStep, FinalAction, FinalActionType, AlterType, OffchainAuctionAlter, ExecutorV1SubmitterData } from "./ExecutorV1Interfaces.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ExecutorV1 is IExecutor, ReentrancyGuard, AbstractMulticallExecutor {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;

    address public immutable authorizedCaller;

    event Executed(
        bytes32 indexed orderId,
        address indexed submitter,
        address indexed target,
        uint8 actionType,
        address token,
        uint256 amount,
        uint256 value
    );

    constructor(address _authorizedCaller) {
        require(_authorizedCaller != address(0), "AUTH_0");
        authorizedCaller = _authorizedCaller;
    }

    modifier onlyAuthorizedCaller() {
        require(msg.sender == authorizedCaller, "NOT_AUTH");
        _;
    }

    function execute(
        bytes32 orderId,
        TokenAmount calldata orderIn,
        Path calldata path,
        address submitter,
        bytes calldata submitterData
    ) external payable onlyAuthorizedCaller nonReentrant {
        ExecutorV1SubmitterData memory s = _decodeSubmitterData(submitterData);
        ExecutorStep memory step = abi.decode(path.cur.message, (ExecutorStep));
        _applyAlter(orderId, step, s.alterData);
        _executeMulticall(s.multicallData, orderIn.token);

        uint256 amountToPropagate = _checkRequirements(step, submitter);
        _runFinalAction(orderId, submitter, path.next, step.finalAction, amountToPropagate, s.finalActionValue);
    }

    function _runFinalAction(
        bytes32 orderId,
        address submitter,
        bytes calldata next,
        FinalAction memory finalAction,
        uint256 amount,
        uint256 finalActionValue
    ) internal {
        require(finalAction.target != address(0), "TARGET_0");
        uint8 actionType = uint8(finalAction.typ);

        if (finalAction.typ == FinalActionType.Transfer) {
            require(finalActionValue == 0, "VALUE_ON_TRANSFER");
            IERC20(finalAction.token).safeTransfer(finalAction.target, amount);
            emit Executed(orderId, submitter, finalAction.target, actionType, finalAction.token, amount, 0);
            return;
        }

        if (finalAction.typ == FinalActionType.Execute) {
            IERC20(finalAction.token).forceApprove(finalAction.target, amount);

            IUserActionExecutor(finalAction.target).executeAndForward{ value: finalActionValue }(
                orderId,
                TokenAmount({ token: finalAction.token, amount: amount }),
                finalAction.message,
                next
            );

            IERC20(finalAction.token).forceApprove(finalAction.target, 0);
            emit Executed(
                orderId,
                submitter,
                finalAction.target,
                actionType,
                finalAction.token,
                amount,
                finalActionValue
            );
            return;
        }

        revert("BAD_ACTION");
    }

    function _checkRequirements(ExecutorStep memory step, address submitter) internal view returns (uint256 amount) {
        require(step.balanceReq.token != address(0), "BAL_ERC20_ONLY");
        require(step.balanceReq.token == step.finalAction.token, "TOKEN_MISMATCH");
        if (step.submitterReq.submitter != address(0))
            require(step.submitterReq.submitter == submitter, "BAD_SUBMITTER");
        if (step.deadlineReq.deadline != 0) require(block.timestamp <= step.deadlineReq.deadline, "DEADLINE");
        uint256 bal = IERC20(step.balanceReq.token).balanceOf(address(this));
        require(bal >= step.balanceReq.minAmount, "BAL_REQ");
        amount = step.balanceReq.useFullBalance ? bal : step.balanceReq.minAmount;
    }

    function _applyAlter(bytes32 orderId, ExecutorStep memory step, bytes memory alterData) internal pure {
        if (step.alterConfig.typ == AlterType.None) {
            require(alterData.length == 0, "ALTER_NOT_ALLOWED");
            return;
        }
        require(alterData.length != 0, "ALTER_MISSING");

        if (step.alterConfig.typ == AlterType.SimpleSubmitter) {
            uint256 newMin = abi.decode(alterData, (uint256));
            require(newMin >= step.balanceReq.minAmount, "ALTER_WEAKER_BAL");
            step.balanceReq.minAmount = newMin;
            return;
        }

        if (step.alterConfig.typ == AlterType.OffchainAuction) {
            require(step.alterConfig.auctionAuthority != address(0), "AUCTION_AUTH_0");
            OffchainAuctionAlter memory a = abi.decode(alterData, (OffchainAuctionAlter));
            require(a.newMinAmount >= step.balanceReq.minAmount, "ALTER_WEAKER_BAL");
            require(a.deadline == step.deadlineReq.deadline, "ALTER_DEADLINE");

            bytes32 digest = keccak256(abi.encode(orderId, a.newMinAmount, a.newSubmitter, a.deadline))
                .toEthSignedMessageHash();
            address signer = ECDSA.recover(digest, a.signature);
            require(signer == step.alterConfig.auctionAuthority, "BAD_AUCTION_SIG");

            step.balanceReq.minAmount = a.newMinAmount;
            step.submitterReq.submitter = a.newSubmitter;
            return;
        }

        revert("BAD_ALTER_TYPE");
    }

    function _decodeSubmitterData(bytes calldata submitterData) internal pure returns (ExecutorV1SubmitterData memory) {
        if (submitterData.length == 0)
            return ExecutorV1SubmitterData({ alterData: "", multicallData: "", finalActionValue: 0 });
        return abi.decode(submitterData, (ExecutorV1SubmitterData));
    }
}
