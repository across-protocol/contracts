// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Order, Path, IExecutor, TokenAmount, TypedData, SubmitterData, IOrderGateway, OrderFundingType, Permit2Funding, AuthorizationFunding, ApprovalFunding } from "./Interfaces.sol";
import { OrderIdLib } from "./OrderIdLib.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts-v4/utils/cryptography/MerkleProof.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts-v4/security/ReentrancyGuard.sol";
import { IPermit2 } from "../external/interfaces/IPermit2.sol";
import { IERC20Auth } from "../external/interfaces/IERC20Auth.sol";

contract OrderGateway is IOrderGateway, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPermit2 public immutable permit2;
    bytes32 public immutable domainHash;
    mapping(address => mapping(bytes32 => bool)) public usedApprovalSalts;

    bytes32 public constant ORDER_ID_WITNESS_TYPEHASH = keccak256("OrderIdWitness(bytes32 orderId)");
    string public constant PERMIT2_ORDER_WITNESS_TYPE =
        "OrderIdWitness witness)OrderIdWitness(bytes32 orderId)TokenPermissions(address token,uint256 amount)";

    error DuplicateApprovalSalt();
    error InvalidExecutor();
    error InvalidSubOrder();
    error InvalidPermit2Salt();
    error UnknownOrderFundingType();

    constructor(address _permit2) {
        permit2 = IPermit2(_permit2);
        domainHash = OrderIdLib.domainHash(block.chainid, address(this));
    }

    // TODO: perhaps this warrants a rename. Since `msg.sender` here does not get recorded as `submitter`. Submitter
    // TODO: is only the one doing `submitWithData` or `fill`. Think about naming
    function submit(
        Order calldata order,
        Path calldata selectedPath,
        bytes32[] calldata pathProof,
        TypedData calldata orderFunding
    ) external payable nonReentrant {
        revert("not implemented");
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

    function fill(bytes32 orderId, SubmitterData calldata submitterData) external payable {
        revert("not implemented");
    }

    function _pullOrderFundingAndComputeOrderId(
        Order calldata order,
        TypedData calldata orderFunding,
        address fundsRecipient
    ) internal returns (bytes32 orderId, address token, uint256 amount) {
        OrderFundingType typ = OrderFundingType(orderFunding.typ);
        if (typ == OrderFundingType.Approval) return _pullFundsApproval(order, orderFunding, fundsRecipient);
        if (typ == OrderFundingType.Permit2) return _pullFundsPermit2(order, orderFunding, fundsRecipient);
        if (typ == OrderFundingType.TransferWithAuthorization)
            return _pullFundsTWA(order, orderFunding, fundsRecipient);

        revert UnknownOrderFundingType();
    }

    function _pullFundsApproval(
        Order calldata order,
        TypedData calldata orderFunding,
        address fundsRecipient
    ) internal returns (bytes32 orderId, address token, uint256 amount) {
        ApprovalFunding memory f = abi.decode(orderFunding.data, (ApprovalFunding));
        if (usedApprovalSalts[msg.sender][f.salt]) revert DuplicateApprovalSalt();
        usedApprovalSalts[msg.sender][f.salt] = true;
        IERC20(f.tokenAmount.token).safeTransferFrom(msg.sender, fundsRecipient, f.tokenAmount.amount);
        return (
            OrderIdLib.orderId(domainHash, uint8(OrderFundingType.Approval), msg.sender, order.root, f.salt),
            f.tokenAmount.token,
            f.tokenAmount.amount
        );
    }

    function _pullFundsPermit2(
        Order calldata order,
        TypedData calldata orderFunding,
        address fundsRecipient
    ) internal returns (bytes32 orderId, address token, uint256 amount) {
        Permit2Funding memory f = abi.decode(orderFunding.data, (Permit2Funding));
        orderId = OrderIdLib.orderId(
            domainHash,
            uint8(OrderFundingType.Permit2),
            f.signer,
            order.root,
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
        Order calldata order,
        TypedData calldata orderFunding,
        address fundsRecipient
    ) internal returns (bytes32 orderId, address token, uint256 amount) {
        AuthorizationFunding memory f = abi.decode(orderFunding.data, (AuthorizationFunding));
        orderId = OrderIdLib.orderId(
            domainHash,
            uint8(OrderFundingType.TransferWithAuthorization),
            f.signer,
            order.root,
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
        for (uint256 i; i < extraFunding.length; ++i) {
            IERC20(extraFunding[i].token).safeTransferFrom(msg.sender, executor, extraFunding[i].amount);
        }
    }

    function _deserializeSignature(bytes memory signature) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(signature.length == 65, "invalid sig length");
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
    }
}
