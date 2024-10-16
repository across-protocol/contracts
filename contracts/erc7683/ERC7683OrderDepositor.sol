// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../external/interfaces/IPermit2.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../libraries/AddressConverters.sol";

import { Output, GaslessCrossChainOrder, OnchainCrossChainOrder, ResolvedCrossChainOrder, IOriginSettler, FillInstruction } from "./ERC7683.sol";
import { AcrossOrderData, AcrossOriginFillerData, ERC7683Permit2Lib, ACROSS_ORDER_DATA_TYPE_HASH } from "./ERC7683Across.sol";

/**
 * @notice ERC7683OrderDepositor processes an external order type and translates it into an AcrossV3 deposit.
 * @dev This contract is abstract because it is intended to be usable by a contract that can accept the deposit
 * as well as one that sends the deposit to another contract.
 * @custom:security-contact bugs@across.to
 */
abstract contract ERC7683OrderDepositor is IOriginSettler {
    using SafeERC20 for IERC20;
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    error WrongSettlementContract();
    error WrongChainId();
    error WrongOrderDataType();
    error WrongExclusiveRelayer();

    // Permit2 contract for this network.
    IPermit2 public immutable PERMIT2;

    // QUOTE_BEFORE_DEADLINE is subtracted from the deadline to get the quote timestamp.
    // This is a somewhat arbitrary conversion, but order creators need some way to precompute the quote timestamp.
    uint256 public immutable QUOTE_BEFORE_DEADLINE;

    /**
     * @notice Construct the Permit2Depositor.
     * @param _permit2 Permit2 contract
     * @param _quoteBeforeDeadline quoteBeforeDeadline is subtracted from the deadline to get the quote timestamp.
     */
    constructor(IPermit2 _permit2, uint256 _quoteBeforeDeadline) {
        PERMIT2 = _permit2;
        QUOTE_BEFORE_DEADLINE = _quoteBeforeDeadline;
    }

    /**
     * @notice Open the order on behalf of the user.
     * @dev This will pull in the user's funds and make the order available to be filled.
     * @param order the ERC7683 compliant order.
     * @param signature signature for the EIP-712 compliant order type.
     * @param fillerData Across-specific fillerData.
     */
    function openFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata signature,
        bytes calldata fillerData
    ) external {
        (
            ResolvedCrossChainOrder memory resolvedOrder,
            AcrossOrderData memory acrossOrderData,
            AcrossOriginFillerData memory acrossOriginFillerData
        ) = _resolveFor(order, fillerData);

        // Verify Permit2 signature and pull user funds into this contract
        _processPermit2Order(order, acrossOrderData, signature);

        _callDeposit(
            order.user,
            acrossOrderData.recipient,
            acrossOrderData.inputToken,
            acrossOrderData.outputToken,
            acrossOrderData.inputAmount,
            acrossOrderData.outputAmount,
            acrossOrderData.destinationChainId,
            acrossOriginFillerData.exclusiveRelayer,
            // Note: simplifying assumption to avoid quote timestamps that cause orders to expire before the deadline.
            SafeCast.toUint32(order.openDeadline - QUOTE_BEFORE_DEADLINE),
            order.fillDeadline,
            acrossOrderData.exclusivityPeriod,
            acrossOrderData.message
        );

        emit Open(keccak256(resolvedOrder.fillInstructions[0].originData), resolvedOrder);
    }

    /**
     * @notice Opens the order.
     * @dev Unlike openFor, this method is callable by the user.
     * @dev This will pull in the user's funds and make the order available to be filled.
     * @param order the ERC7683 compliant order.
     */
    function open(OnchainCrossChainOrder calldata order) external {
        (ResolvedCrossChainOrder memory resolvedOrder, AcrossOrderData memory acrossOrderData) = _resolve(order);

        IERC20(acrossOrderData.inputToken.toAddress()).safeTransferFrom(
            msg.sender,
            address(this),
            acrossOrderData.inputAmount
        );

        _callDeposit(
            msg.sender.toBytes32(),
            acrossOrderData.recipient,
            acrossOrderData.inputToken,
            acrossOrderData.outputToken,
            acrossOrderData.inputAmount,
            acrossOrderData.outputAmount,
            acrossOrderData.destinationChainId,
            acrossOrderData.exclusiveRelayer,
            // Note: simplifying assumption to avoid the order type having to bake in the quote timestamp.
            SafeCast.toUint32(block.timestamp),
            order.fillDeadline,
            acrossOrderData.exclusivityPeriod,
            acrossOrderData.message
        );

        emit Open(keccak256(resolvedOrder.fillInstructions[0].originData), resolvedOrder);
    }

    /**
     * @notice Constructs a ResolvedOrder from a GaslessCrossChainOrder and originFillerData.
     * @param order the ERC-7683 compliant order.
     * @param originFillerData Across-specific fillerData.
     */
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        public
        view
        returns (ResolvedCrossChainOrder memory resolvedOrder)
    {
        (resolvedOrder, , ) = _resolveFor(order, originFillerData);
    }

    /**
     * @notice Constructs a ResolvedOrder from a CrossChainOrder.
     * @param order the ERC7683 compliant order.
     */
    function resolve(OnchainCrossChainOrder calldata order)
        public
        view
        returns (ResolvedCrossChainOrder memory resolvedOrder)
    {
        (resolvedOrder, ) = _resolve(order);
    }

    /**
     * @notice Decodes the Across specific orderData and fillerData into descriptive types.
     * @param orderData the orderData field of the ERC7683 compliant order.
     * @param fillerData Across-specific fillerData.
     * @return acrossOrderData decoded AcrossOrderData.
     * @return acrossOriginFillerData decoded AcrossOriginFillerData.
     */
    function decode(bytes memory orderData, bytes memory fillerData)
        public
        pure
        returns (AcrossOrderData memory, AcrossOriginFillerData memory)
    {
        return (abi.decode(orderData, (AcrossOrderData)), abi.decode(fillerData, (AcrossOriginFillerData)));
    }

    /**
     * @notice Gets the current time.
     * @return uint for the current timestamp.
     */
    function getCurrentTime() public view virtual returns (uint32) {
        return SafeCast.toUint32(block.timestamp); // solhint-disable-line not-rely-on-time
    }

    function _resolveFor(GaslessCrossChainOrder calldata order, bytes calldata fillerData)
        internal
        view
        returns (
            ResolvedCrossChainOrder memory resolvedOrder,
            AcrossOrderData memory acrossOrderData,
            AcrossOriginFillerData memory acrossOriginFillerData
        )
    {
        // Ensure that order was intended to be settled by Across.
        if (order.originSettler != address(this).toBytes32()) {
            revert WrongSettlementContract();
        }

        if (order.originChainId != block.chainid) {
            revert WrongChainId();
        }

        if (order.orderDataType != ACROSS_ORDER_DATA_TYPE_HASH) {
            revert WrongOrderDataType();
        }

        // Extract Across-specific params.
        (acrossOrderData, acrossOriginFillerData) = decode(order.orderData, fillerData);

        if (
            acrossOrderData.exclusiveRelayer != address(0).toBytes32() &&
            acrossOrderData.exclusiveRelayer != acrossOriginFillerData.exclusiveRelayer
        ) {
            revert WrongExclusiveRelayer();
        }

        Output[] memory maxSpent = new Output[](1);
        maxSpent[0] = Output({
            token: acrossOrderData.outputToken,
            amount: acrossOrderData.outputAmount,
            recipient: acrossOrderData.recipient,
            chainId: acrossOrderData.destinationChainId
        });

        // We assume that filler takes repayment on the origin chain in which case the filler output
        // will always be equal to the input amount. If the filler requests repayment somewhere else then
        // the filler output will be equal to the input amount less a fee based on the chain they request
        // repayment on.
        Output[] memory minReceived = new Output[](1);
        minReceived[0] = Output({
            token: acrossOrderData.inputToken,
            amount: acrossOrderData.inputAmount,
            recipient: acrossOriginFillerData.exclusiveRelayer,
            chainId: SafeCast.toUint32(block.chainid)
        });

        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        fillInstructions[0] = FillInstruction({
            destinationChainId: acrossOrderData.destinationChainId,
            destinationSettler: _destinationSettler(acrossOrderData.destinationChainId),
            originData: abi.encode(
                order.user,
                acrossOrderData.recipient,
                acrossOriginFillerData.exclusiveRelayer,
                acrossOrderData.inputToken,
                acrossOrderData.outputToken,
                acrossOrderData.inputAmount,
                acrossOrderData.outputAmount,
                block.chainid,
                _currentDepositId(),
                order.fillDeadline,
                acrossOrderData.exclusivityPeriod,
                acrossOrderData.message
            )
        });

        resolvedOrder = ResolvedCrossChainOrder({
            user: order.user,
            originChainId: order.originChainId,
            openDeadline: order.openDeadline,
            fillDeadline: order.fillDeadline,
            minReceived: minReceived,
            maxSpent: maxSpent,
            fillInstructions: fillInstructions
        });
    }

    function _resolve(OnchainCrossChainOrder calldata order)
        internal
        view
        returns (ResolvedCrossChainOrder memory resolvedOrder, AcrossOrderData memory acrossOrderData)
    {
        if (order.orderDataType != ACROSS_ORDER_DATA_TYPE_HASH) {
            revert WrongOrderDataType();
        }

        // Extract Across-specific params.
        acrossOrderData = abi.decode(order.orderData, (AcrossOrderData));

        Output[] memory maxSpent = new Output[](1);
        maxSpent[0] = Output({
            token: acrossOrderData.outputToken,
            amount: acrossOrderData.outputAmount,
            recipient: acrossOrderData.recipient,
            chainId: acrossOrderData.destinationChainId
        });

        // We assume that filler takes repayment on the origin chain in which case the filler output
        // will always be equal to the input amount. If the filler requests repayment somewhere else then
        // the filler output will be equal to the input amount less a fee based on the chain they request
        // repayment on.
        Output[] memory minReceived = new Output[](1);
        minReceived[0] = Output({
            token: acrossOrderData.inputToken,
            amount: acrossOrderData.inputAmount,
            recipient: acrossOrderData.exclusiveRelayer,
            chainId: SafeCast.toUint32(block.chainid)
        });

        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        fillInstructions[0] = FillInstruction({
            destinationChainId: acrossOrderData.destinationChainId,
            destinationSettler: _destinationSettler(acrossOrderData.destinationChainId),
            originData: abi.encode(
                msg.sender,
                acrossOrderData.recipient,
                acrossOrderData.exclusiveRelayer,
                acrossOrderData.inputToken,
                acrossOrderData.outputToken,
                acrossOrderData.inputAmount,
                acrossOrderData.outputAmount,
                block.chainid,
                _currentDepositId(),
                order.fillDeadline,
                acrossOrderData.exclusivityPeriod,
                acrossOrderData.message
            )
        });

        resolvedOrder = ResolvedCrossChainOrder({
            user: msg.sender.toBytes32(),
            originChainId: SafeCast.toUint64(block.chainid),
            openDeadline: type(uint32).max, // no deadline since the user is sending it
            fillDeadline: order.fillDeadline,
            minReceived: minReceived,
            maxSpent: maxSpent,
            fillInstructions: fillInstructions
        });
    }

    function _processPermit2Order(
        GaslessCrossChainOrder memory order,
        AcrossOrderData memory acrossOrderData,
        bytes memory signature
    ) internal {
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({
                token: acrossOrderData.inputToken.toAddress(),
                amount: acrossOrderData.inputAmount
            }),
            nonce: order.nonce,
            deadline: order.openDeadline
        });

        IPermit2.SignatureTransferDetails memory signatureTransferDetails = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: acrossOrderData.inputAmount
        });

        // Pull user funds.
        PERMIT2.permitWitnessTransferFrom(
            permit,
            signatureTransferDetails,
            order.user.toAddress(),
            ERC7683Permit2Lib.hashOrder(order, ERC7683Permit2Lib.hashOrderData(acrossOrderData)), // witness data hash
            ERC7683Permit2Lib.PERMIT2_ORDER_TYPE, // witness data type string
            signature
        );
    }

    function _callDeposit(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes memory message
    ) internal virtual;

    function _currentDepositId() internal view virtual returns (uint32);

    function _destinationSettler(uint256 chainId) internal view virtual returns (bytes32);
}
