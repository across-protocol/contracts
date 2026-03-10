// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import "./Interfaces.sol";
import "../external/interfaces/IPermit2.sol";
import "../external/interfaces/IERC20Auth.sol";
import "../upgradeable/EIP712CrossChainUpgradeable.sol";

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import { SignatureChecker } from "@openzeppelin/contracts-v4/utils/cryptography/SignatureChecker.sol";
import { MerkleProof } from "@openzeppelin/contracts-v4/utils/cryptography/MerkleProof.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/security/ReentrancyGuardUpgradeable.sol";

contract OrderGateway is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712CrossChainUpgradeable,
    IOrderGateway
{
    using SafeERC20 for IERC20;

    enum FundingType {
        Approval,
        Permit,
        Permit2,
        Authorization,
        Native
    }

    struct Funding {
        FundingType typ;
        bytes data;
    }

    struct ApprovalFunding {
        address token;
        uint256 amount;
    }

    struct PermitFunding {
        address owner;
        address token;
        uint256 amount;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes orderSig;
    }

    struct Permit2Funding {
        address owner;
        IPermit2.PermitTransferFrom permit;
        uint256 amount;
        bytes signature;
    }

    struct AuthorizationFunding {
        address owner;
        address token;
        uint256 amount;
        uint256 validAfter;
        uint256 validBefore;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct NativeFunding {
        uint256 amount;
    }

    IExecutor public executor;
    IPermit2 public permit2;

    mapping(bytes32 => bool) public usedOrderIds;
    mapping(address => mapping(bytes32 => bool)) public consumedPermitOrderWitness;

    bytes32 public constant GASLESS_ORDER_TYPEHASH = keccak256("GaslessOrder(bytes32 orderId,address submitter)");
    bytes32 public constant ORDER_WITNESS_TYPEHASH = keccak256("OrderWitness(bytes32 orderId)");
    string public constant PERMIT2_ORDER_WITNESS_TYPE =
        "OrderWitness witness)OrderWitness(bytes32 orderId)TokenPermissions(address token,uint256 amount)";

    event ExecutorSet(address indexed executor);
    event Permit2Set(address indexed permit2);
    event OrderSubmitted(bytes32 indexed orderId, address indexed submitter, address token, uint256 amount);

    error InvalidMerkleRoute();
    error InvalidFunding();
    error InvalidPermitOrderWitness();
    error PermitOrderWitnessUsed();
    error DuplicateOrderId();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _executor, address _permit2) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __EIP712_init("USDFree-OrderGateway", "1.0.0");

        _transferOwnership(_owner);
        _setExecutor(_executor);
        _setPermit2(_permit2);
    }

    function setExecutor(address _executor) external onlyOwner {
        _setExecutor(_executor);
    }

    function setPermit2(address _permit2) external onlyOwner {
        _setPermit2(_permit2);
    }

    function computeOrderId(MerkleOrder calldata order) public view returns (bytes32) {
        return keccak256(abi.encode(_domainSeparatorV4(block.chainid), order.salt, keccak256(abi.encode(order))));
    }

    function submit(
        MerkleOrder calldata order,
        MerkleRoute calldata route,
        bytes calldata funding,
        SubmitterData calldata submitterData
    ) external payable override nonReentrant {
        if (!_verifyRoute(order.routesRoot, route)) revert InvalidMerkleRoute();

        bytes32 orderId = computeOrderId(order);
        if (usedOrderIds[orderId]) revert DuplicateOrderId();
        usedOrderIds[orderId] = true;

        (address userTokenIn, uint256 userAmountIn, uint256 userNativeAmount) = _pullFundingAndHandoverToExecutor(
            orderId,
            funding
        );
        if (msg.value < userNativeAmount) revert InvalidFunding();
        uint256 submitterNativeAmount = msg.value - userNativeAmount;
        _pullExtraFunding(msg.sender, submitterData.extraErc20Funding);

        executor.execute{ value: userNativeAmount + submitterNativeAmount }(
            msg.sender,
            orderId,
            userTokenIn,
            userAmountIn,
            submitterNativeAmount,
            submitterData.parts,
            route.stepAndNext
        );

        emit OrderSubmitted(orderId, msg.sender, userTokenIn, userAmountIn);
    }

    function _pullFundingAndHandoverToExecutor(
        bytes32 orderId,
        bytes calldata funding
    ) internal returns (address token, uint256 amount, uint256 nativeAmount) {
        Funding memory fundingData = abi.decode(funding, (Funding));

        if (fundingData.typ == FundingType.Approval) {
            ApprovalFunding memory approval = abi.decode(fundingData.data, (ApprovalFunding));
            uint256 pulled = _pullToGateway(approval.token, msg.sender, approval.amount);
            uint256 received = _sendLocalTokenToExecutor(approval.token, pulled);
            return (approval.token, received, 0);
        }

        if (fundingData.typ == FundingType.Permit) {
            PermitFunding memory permitFunding = abi.decode(fundingData.data, (PermitFunding));
            _verifyPermitFundingSignature(orderId, permitFunding.owner, permitFunding.orderSig);
            _redeemPermitFunding(permitFunding);
            uint256 pulled = _pullToGateway(permitFunding.token, permitFunding.owner, permitFunding.amount);
            uint256 received = _sendLocalTokenToExecutor(permitFunding.token, pulled);
            return (permitFunding.token, received, 0);
        }

        if (fundingData.typ == FundingType.Permit2) {
            Permit2Funding memory permit2Funding = abi.decode(fundingData.data, (Permit2Funding));
            if (permit2Funding.permit.permitted.amount < permit2Funding.amount) revert InvalidFunding();
            uint256 beforeBal = IERC20(permit2Funding.permit.permitted.token).balanceOf(address(this));

            permit2.permitWitnessTransferFrom(
                permit2Funding.permit,
                IPermit2.SignatureTransferDetails({ to: address(this), requestedAmount: permit2Funding.amount }),
                permit2Funding.owner,
                keccak256(abi.encode(ORDER_WITNESS_TYPEHASH, orderId)),
                PERMIT2_ORDER_WITNESS_TYPE,
                permit2Funding.signature
            );

            uint256 pulled = IERC20(permit2Funding.permit.permitted.token).balanceOf(address(this)) - beforeBal;
            uint256 received = _sendLocalTokenToExecutor(permit2Funding.permit.permitted.token, pulled);
            return (permit2Funding.permit.permitted.token, received, 0);
        }

        if (fundingData.typ == FundingType.Authorization) {
            AuthorizationFunding memory authFunding = abi.decode(fundingData.data, (AuthorizationFunding));
            uint256 beforeLocal = IERC20(authFunding.token).balanceOf(address(this));

            IERC20Auth(authFunding.token).receiveWithAuthorization(
                authFunding.owner,
                address(this),
                authFunding.amount,
                authFunding.validAfter,
                authFunding.validBefore,
                orderId,
                authFunding.v,
                authFunding.r,
                authFunding.s
            );

            uint256 pulled = IERC20(authFunding.token).balanceOf(address(this)) - beforeLocal;
            uint256 received = _sendLocalTokenToExecutor(authFunding.token, pulled);
            return (authFunding.token, received, 0);
        }

        if (fundingData.typ == FundingType.Native) {
            NativeFunding memory nativeFunding = abi.decode(fundingData.data, (NativeFunding));
            return (address(0), nativeFunding.amount, nativeFunding.amount);
        }

        revert InvalidFunding();
    }

    function _redeemPermitFunding(PermitFunding memory permitFunding) internal {
        // Keep behavior permissive if permit has already been redeemed.
        try
            IERC20Permit(permitFunding.token).permit(
                permitFunding.owner,
                address(this),
                permitFunding.amount,
                permitFunding.deadline,
                permitFunding.v,
                permitFunding.r,
                permitFunding.s
            )
        {} catch {}
    }

    function _verifyPermitFundingSignature(bytes32 orderId, address owner, bytes memory sig) internal {
        if (consumedPermitOrderWitness[owner][orderId]) revert PermitOrderWitnessUsed();

        bytes32 structHash = keccak256(abi.encode(GASLESS_ORDER_TYPEHASH, orderId, msg.sender));
        bytes32 digest = _hashTypedDataV4(structHash, block.chainid);
        if (!SignatureChecker.isValidSignatureNow(owner, digest, sig)) revert InvalidPermitOrderWitness();

        consumedPermitOrderWitness[owner][orderId] = true;
    }

    function _pullExtraFunding(address submitter, TokenAmount[] calldata extraErc20Funding) internal {
        uint256 length = extraErc20Funding.length;
        for (uint256 i = 0; i < length; ++i) {
            TokenAmount calldata funding = extraErc20Funding[i];
            if (funding.token == address(0)) revert InvalidFunding();
            uint256 pulled = _pullToGateway(funding.token, submitter, funding.amount);
            _sendLocalTokenToExecutor(funding.token, pulled);
        }
    }

    function _pullToGateway(address token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        return IERC20(token).balanceOf(address(this)) - beforeBal;
    }

    function _sendLocalTokenToExecutor(address token, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBal = IERC20(token).balanceOf(address(executor));
        IERC20(token).safeTransfer(address(executor), amount);
        return IERC20(token).balanceOf(address(executor)) - beforeBal;
    }

    function _verifyRoute(bytes32 routesRoot, MerkleRoute calldata route) internal pure returns (bool) {
        bytes32 leaf = keccak256(abi.encode(route.stepAndNext));
        return MerkleProof.verify(route.proof, routesRoot, leaf);
    }

    function _setExecutor(address _executor) internal {
        if (_executor == address(0)) revert InvalidFunding();
        executor = IExecutor(_executor);
        emit ExecutorSet(_executor);
    }

    function _setPermit2(address _permit2) internal {
        if (_permit2 == address(0)) revert InvalidFunding();
        permit2 = IPermit2(_permit2);
        emit Permit2Set(_permit2);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
