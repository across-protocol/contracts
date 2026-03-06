// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Order, Path, IExecutor, TokenAmount, TypedData, SubmitterData, IOrderGateway, OrderFundingType, Permit2Funding, AuthorizationFunding, ApprovalFunding } from "./Interfaces.sol";
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

    IPermit2 public permit2;
    mapping(address => mapping(bytes32 => bool)) public usedApprovalSalts;
    mapping(bytes32 => PendingOrder) internal pendingOrders;

    bytes32 public constant ORDER_ID_WITNESS_TYPEHASH = keccak256("OrderIdWitness(bytes32 orderId)");
    string public constant PERMIT2_ORDER_WITNESS_TYPE =
        "OrderIdWitness witness)OrderIdWitness(bytes32 orderId)TokenPermissions(address token,uint256 amount)";

    error DuplicateApprovalSalt();
    error InvalidAddress();
    error InvalidExecutor();
    error InvalidSubOrder();
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

    function _orderHash(Order calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function setPermit2(address _permit2) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_permit2 == address(0)) revert InvalidAddress();
        permit2 = IPermit2(_permit2);
    }

    function domainHash() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
