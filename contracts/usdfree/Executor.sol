// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { StepType, StepAndNext, IExecutor, TokenAmount, OrderFundingType, MerkleOrder, MerkleRoute, TypedData, SubmitterData, IOrderGateway, Permit2Funding, AuthorizationFunding } from "./Interfaces.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts-v4/utils/cryptography/MerkleProof.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/UUPSUpgradeable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/EIP712Upgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/security/ReentrancyGuardUpgradeable.sol";
import { IPermit2 } from "../external/interfaces/IPermit2.sol";
import { IERC20Auth } from "../external/interfaces/IERC20Auth.sol";

contract Executor is IExecutor {
    // OrderGateway or OrderStore
    address immutable authorizedCaller;

    constructor(address _authorizedCaller) {
        authorizedCaller = _authorizedCaller;
    }

    modifier onlyAuthorizedCaller() {
        require(msg.sender == authorizedCaller);
        _;
    }

    function execute(
        bytes32 orderId,
        TokenAmount calldata userTokenAmount,
        StepAndNext calldata stepAndNext,
        address submitter,
        bytes[] calldata submitterParts
    ) external payable onlyAuthorizedCaller {
        StepType typ = stepAndNext.curStep.typ;

        if (typ == StepType.AlterSubmitterUser) {
            _executeAlterSubmitterUserSequence(orderId, userTokenAmount, stepAndNext, submitter, submitterParts);
        }

        if (typ == StepType.AlterSubmitterUser) {
            // TODO
            revert("not implemented");
        }

        if (typ == StepType.AlterSubmitterUser) {
            // TODO
            revert("not implemented");
        }

        revert("step type not supported");
    }

    function _executeAlterSubmitterUserSequence(
        bytes32 orderId,
        TokenAmount calldata userTokenAmount,
        StepAndNext calldata stepAndNext,
        address submitter,
        bytes[] calldata submitterParts
    ) internal {
        uint256 userPartsCursor;
        uint256 submitterPartsCursor;

        // TODO: (Changes memory changes, userPartsCursor, submitterPartsCursor) = _executeAlterSubstep(userPartsCursor, userParts, submitterPartsCursor, submitterParts);
        // TODO: submitterPartsCursor = _executeSubmitterSubstep(submitterPartsCursor, submitterParts); // Only MulticallHandler instructons at this point. Executor needs to be able to act like a MulticallHandler instead of calling some extrenal multicallHandler contract
        // TODO: userPartsCursor = _executeUserSubstep(orderId, userPartsCursor, userParts, changes);

        // TODO: require userPartsCursor = userParts.length && same for submitter
    }
}
