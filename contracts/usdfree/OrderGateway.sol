// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { IExecutor, TokenAmount, OrderFundingType, MerkleOrder, MerkleRoute, TypedData, SubmitterData, IOrderGateway, Permit2Funding, AuthorizationFunding } from "./Interfaces.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts-v4/utils/cryptography/MerkleProof.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/UUPSUpgradeable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/EIP712Upgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/security/ReentrancyGuardUpgradeable.sol";
import { IPermit2 } from "../external/interfaces/IPermit2.sol";
import { IERC20Auth } from "../external/interfaces/IERC20Auth.sol";

contract OrderGateway is
    IOrderGateway,
    UUPSUpgradeable,
    EIP712Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    IExecutor public executor;
    IPermit2 public permit2;
    mapping(bytes32 => bool) public usedOrderIds;

    bytes32 public constant MERKLE_ORDER_TYPEHASH = keccak256("MerkleOrder(bytes32 salt,bytes32 routesRoot)");
    bytes32 public constant ORDER_ID_WITNESS_TYPEHASH = keccak256("OrderIdWitness(bytes32 orderId)");
    string public constant PERMIT2_ORDER_WITNESS_TYPE =
        "OrderIdWitness witness)OrderIdWitness(bytes32 orderId)TokenPermissions(address token,uint256 amount)";

    error DuplicateOrderId();
    error InvalidRoute();
    error UnknownOrderFundingType();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _executor, address _permit2) external initializer {
        __UUPSUpgradeable_init();
        __EIP712_init("USDFree-OrderGateway", "1");
        __Ownable_init();
        __ReentrancyGuard_init();
        executor = IExecutor(_executor);
        permit2 = IPermit2(_permit2);
    }

    function submit(
        MerkleOrder calldata order,
        MerkleRoute calldata route,
        TypedData calldata orderFunding,
        SubmitterData calldata submitterData
    ) external payable nonReentrant {
        bytes32 orderId = _calculateOrderId(order);
        if (usedOrderIds[orderId]) revert DuplicateOrderId();
        usedOrderIds[orderId] = true;

        // Verify that MerkleRoute is a part of a MerkleOrder
        bytes32 leaf = keccak256(abi.encode(route.stepAndNext));
        if (!MerkleProof.verify(route.proof, order.routesRoot, leaf)) revert InvalidRoute();

        // Pull order funding from the authorizing party (usually, user)
        (address token, uint256 amount) = _pullOrderFunding(orderId, orderFunding);

        // Push all funding to executor (order funding + submitter extra funding)
        _pushFundingToExecutor(token, amount, submitterData.extraFunding);

        executor.execute{ value: msg.value }(
            orderId,
            TokenAmount(token, amount),
            route.stepAndNext,
            msg.sender,
            submitterData.parts
        );
    }

    function _pullOrderFunding(
        bytes32 orderId,
        TypedData calldata orderFunding
    ) internal returns (address token, uint256 amount) {
        // TODO: can we implement this function in such a way that we transfer to executor in a single trasnfer to save gas? For all of the funding methods
        OrderFundingType typ = OrderFundingType(orderFunding.typ);

        if (typ == OrderFundingType.Approval) {
            TokenAmount memory f = abi.decode(orderFunding.data, (TokenAmount));
            IERC20(f.token).safeTransferFrom(msg.sender, address(this), f.amount);
            return (f.token, f.amount);
        }

        if (typ == OrderFundingType.Permit2) {
            Permit2Funding memory f = abi.decode(orderFunding.data, (Permit2Funding));
            bytes32 witness = keccak256(abi.encode(ORDER_ID_WITNESS_TYPEHASH, orderId));
            permit2.permitWitnessTransferFrom(
                IPermit2.PermitTransferFrom({
                    permitted: IPermit2.TokenPermissions({ token: f.tokenAmount.token, amount: f.tokenAmount.amount }),
                    nonce: f.nonce,
                    deadline: f.deadline
                }),
                IPermit2.SignatureTransferDetails({ to: address(this), requestedAmount: f.tokenAmount.amount }),
                f.signer,
                witness,
                PERMIT2_ORDER_WITNESS_TYPE,
                f.signature
            );
            return (f.tokenAmount.token, f.tokenAmount.amount);
        }

        if (typ == OrderFundingType.TransferWithAuthorization) {
            AuthorizationFunding memory f = abi.decode(orderFunding.data, (AuthorizationFunding));
            (bytes32 r, bytes32 s, uint8 v) = _deserializeSignature(f.signature);
            IERC20Auth(f.tokenAmount.token).receiveWithAuthorization(
                f.signer,
                address(this),
                f.tokenAmount.amount,
                f.validAfter,
                f.validBefore,
                orderId, // orderId as nonce (also acts as witness)
                v,
                r,
                s
            );
            return (f.tokenAmount.token, f.tokenAmount.amount);
        }

        revert UnknownOrderFundingType();
    }

    /// @dev Pushes order funding + submitter extra funding to executor. If the first extra funding token matches
    /// the order funding token, combines them into a single transfer to save gas.
    function _pushFundingToExecutor(
        address orderToken,
        uint256 orderAmount,
        TokenAmount[] calldata extraFunding
    ) internal {
        uint256 startIdx;
        if (extraFunding.length > 0 && extraFunding[0].token == orderToken) {
            IERC20(orderToken).safeTransferFrom(msg.sender, address(this), extraFunding[0].amount);
            orderAmount += extraFunding[0].amount;
            startIdx = 1;
        }

        IERC20(orderToken).safeTransfer(address(executor), orderAmount);

        for (uint256 i = startIdx; i < extraFunding.length; i++) {
            IERC20(extraFunding[i].token).safeTransferFrom(msg.sender, address(executor), extraFunding[i].amount);
        }
    }

    function _calculateOrderId(MerkleOrder calldata order) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(MERKLE_ORDER_TYPEHASH, order)));
    }

    // TODO: make this and `PeripherySigningLib.deserializeSignature` use the same code (although might not be trivial with `memory` vs `calldata` arg type)
    function _deserializeSignature(bytes memory signature) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(signature.length == 65, "invalid sig length");
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
