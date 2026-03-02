// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IExecutor, TokenAmount, OrderFundingType, MerkleOrder, MerkleRoute, TypedData, SubmitterData, IOrderGateway } from "./Interfaces.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

// TODO: move these into some other file together with the OrderFunding enum
struct OrderFundingApproval {
    address token;
    uint256 amount;
}

// TODO: make UUPSUpgradeable
contract OrderGateway is IOrderGateway {
    IExecutor executor;
    mapping(bytes32 => bool) usedOrderIds;

    // TODO: EIP712 for domain separation
    constructor(address _executor) {
        executor = IExecutor(_executor);
    }

    function submit(
        MerkleOrder calldata order,
        MerkleRoute calldata route,
        // Funding by the party authorizing the order. Funding has the amount of a single ERC20 token
        TypedData calldata orderFunding,
        SubmitterData calldata submitterData
    ) external payable {
        bytes32 orderId = _calculateOrderId(order);
        if (usedOrderIds[orderId]) revert("duplicate orderId");
        // TODO: check merkle proof and decode StepAndNext
        _pullOrderFunding(orderId, orderFunding);
        // TODO: _pushFundingToExecutor
        // TODO: call executor.execute(orderId, userTokenAmount, stepAndNext, submitter, submitterParts);
    }

    function _pullOrderFunding(
        bytes32 orderId,
        TypedData calldata orderFunding
    ) internal returns (address token, uint256 amount) {
        OrderFundingType typ = OrderFundingType(orderFunding.typ);
        if (typ == OrderFundingType.Approval) {
            TokenAmount memory fundingParams = abi.decode(orderFunding.data, (TokenAmount));
            // TODO: perhaps transfer directly to Executor?
            IERC20(fundingParams.token).transferFrom(msg.sender, address(this), fundingParams.amount);
            return (fundingParams.token, fundingParams.amount);
        }

        if (typ == OrderFundingType.Permit2) {
            // TODO: orderId should be a witness
            revert("not implemented");
        }

        if (typ == OrderFundingType.TransferWithAuthorization) {
            // TODO: orderId should be a nonce (also acts as witness)
            revert("not implemented");
        }

        revert("unknown order funding type");
    }

    function _calculateOrderId(MerkleOrder calldata order) internal pure returns (bytes32) {
        // TODO: domain separation
        return keccak256(abi.encode(order));
    }
}
