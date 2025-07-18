// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../external/interfaces/IPermit2.sol";
import { V3SpokePoolInterface } from "../interfaces/V3SpokePoolInterface.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Output, GaslessCrossChainOrder, OnchainCrossChainOrder, ResolvedCrossChainOrder, IOriginSettler, FillInstruction } from "./ERC7683.sol";
import { AcrossOrderData, AcrossOriginFillerData, ERC7683Permit2Lib, ACROSS_ORDER_DATA_TYPE_HASH } from "./ERC7683Permit2Lib.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../libraries/AddressConverters.sol";

/**
 * @notice ERC7683OrderDepositor processes an external order type and translates it into an AcrossV3 deposit.
 * @dev This contract is abstract because it is intended to be usable by a contract that can accept the deposit
 * as well as one that sends the deposit to another contract.
 * @custom:security-contact bugs@across.to
 */
abstract contract ERC7683OrderDepositor is IOriginSettler {
    using SafeERC20 for IERC20;
    using Bytes32ToAddress for bytes32;
    using AddressToBytes32 for address;

    error WrongSettlementContract();
    error WrongChainId();
    error WrongOrderDataType();
    error WrongExclusiveRelayer();
    error NoDestinationSettlerForChain(uint256 chainId);

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
     * @param originFillerData Across-specific fillerData.
     */
    function openFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata signature,
        bytes calldata originFillerData
    ) external {
        (
            ResolvedCrossChainOrder memory resolvedOrder,
            AcrossOrderData memory acrossOrderData,
            AcrossOriginFillerData memory acrossOriginFillerData
        ) = _resolveFor(order, originFillerData);

        // Verify Permit2 signature and pull user funds into this contract
        _processPermit2Order(order, acrossOrderData, signature);

        _callDeposit(
            order.user,
            acrossOrderData.recipient.toAddress(),
            acrossOrderData.inputToken,
            acrossOrderData.outputToken,
            acrossOrderData.inputAmount,
            acrossOrderData.outputAmount,
            acrossOrderData.destinationChainId,
            acrossOriginFillerData.exclusiveRelayer,
            acrossOrderData.depositNonce,
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

        IERC20(acrossOrderData.inputToken).safeTransferFrom(msg.sender, address(this), acrossOrderData.inputAmount);

        _callDeposit(
            msg.sender,
            acrossOrderData.recipient.toAddress(),
            acrossOrderData.inputToken,
            acrossOrderData.outputToken,
            acrossOrderData.inputAmount,
            acrossOrderData.outputAmount,
            acrossOrderData.destinationChainId,
            acrossOrderData.exclusiveRelayer,
            acrossOrderData.depositNonce,
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

    /**
     * @notice Convenience method to compute the Across depositId for orders sent through 7683.
     * @dev if a 0 depositNonce is used, the depositId will not be deterministic (meaning it can change depending on
     * when the open txn is mined), but you will be safe from collisions. See the unsafeDepositV3 method on SpokePool
     * for more details on how to choose between deterministic and non-deterministic.
     * @param depositNonce the depositNonce field in the order.
     * @param depositor the sender or signer of the order.
     * @return the resulting Across depositId.
     */
    function computeDepositId(uint256 depositNonce, address depositor) public view virtual returns (uint256);

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
        if (order.originSettler != address(this)) {
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
            acrossOrderData.exclusiveRelayer != address(0) &&
            acrossOrderData.exclusiveRelayer != acrossOriginFillerData.exclusiveRelayer
        ) {
            revert WrongExclusiveRelayer();
        }

        Output[] memory maxSpent = new Output[](1);
        maxSpent[0] = Output({
            token: acrossOrderData.outputToken.toBytes32(),
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
            token: acrossOrderData.inputToken.toBytes32(),
            amount: acrossOrderData.inputAmount,
            recipient: acrossOriginFillerData.exclusiveRelayer.toBytes32(),
            chainId: block.chainid
        });

        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        V3SpokePoolInterface.V3RelayData memory relayData;
        relayData.depositor = order.user.toBytes32();
        relayData.recipient = acrossOrderData.recipient;
        relayData.exclusiveRelayer = acrossOriginFillerData.exclusiveRelayer.toBytes32();
        relayData.inputToken = acrossOrderData.inputToken.toBytes32();
        relayData.outputToken = acrossOrderData.outputToken.toBytes32();
        relayData.inputAmount = acrossOrderData.inputAmount;
        relayData.outputAmount = acrossOrderData.outputAmount;
        relayData.originChainId = block.chainid;
        relayData.depositId = computeDepositId(acrossOrderData.depositNonce, order.user);
        relayData.fillDeadline = order.fillDeadline;
        relayData.exclusivityDeadline = acrossOrderData.exclusivityPeriod;
        relayData.message = acrossOrderData.message;
        fillInstructions[0] = FillInstruction({
            destinationChainId: SafeCast.toUint64(acrossOrderData.destinationChainId),
            destinationSettler: _destinationSettler(acrossOrderData.destinationChainId).toBytes32(),
            originData: abi.encode(relayData)
        });

        resolvedOrder = ResolvedCrossChainOrder({
            user: order.user,
            originChainId: order.originChainId,
            openDeadline: order.openDeadline,
            fillDeadline: order.fillDeadline,
            minReceived: minReceived,
            maxSpent: maxSpent,
            fillInstructions: fillInstructions,
            orderId: keccak256(abi.encode(relayData, acrossOrderData.destinationChainId))
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
            token: acrossOrderData.outputToken.toBytes32(),
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
            token: acrossOrderData.inputToken.toBytes32(),
            amount: acrossOrderData.inputAmount,
            recipient: acrossOrderData.exclusiveRelayer.toBytes32(),
            chainId: block.chainid
        });

        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        V3SpokePoolInterface.V3RelayData memory relayData;
        relayData.depositor = msg.sender.toBytes32();
        relayData.recipient = acrossOrderData.recipient;
        relayData.exclusiveRelayer = acrossOrderData.exclusiveRelayer.toBytes32();
        relayData.inputToken = acrossOrderData.inputToken.toBytes32();
        relayData.outputToken = acrossOrderData.outputToken.toBytes32();
        relayData.inputAmount = acrossOrderData.inputAmount;
        relayData.outputAmount = acrossOrderData.outputAmount;
        relayData.originChainId = block.chainid;
        relayData.depositId = computeDepositId(acrossOrderData.depositNonce, msg.sender);
        relayData.fillDeadline = order.fillDeadline;
        relayData.exclusivityDeadline = acrossOrderData.exclusivityPeriod;
        relayData.message = acrossOrderData.message;
        fillInstructions[0] = FillInstruction({
            destinationChainId: SafeCast.toUint64(acrossOrderData.destinationChainId),
            destinationSettler: _destinationSettler(acrossOrderData.destinationChainId).toBytes32(),
            originData: abi.encode(relayData)
        });

        resolvedOrder = ResolvedCrossChainOrder({
            user: msg.sender,
            originChainId: block.chainid,
            openDeadline: type(uint32).max, // no deadline since the user is sending it
            fillDeadline: order.fillDeadline,
            minReceived: minReceived,
            maxSpent: maxSpent,
            fillInstructions: fillInstructions,
            orderId: keccak256(abi.encode(relayData, acrossOrderData.destinationChainId))
        });
    }

    function _processPermit2Order(
        GaslessCrossChainOrder memory order,
        AcrossOrderData memory acrossOrderData,
        bytes memory signature
    ) internal {
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({
                token: acrossOrderData.inputToken,
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
            order.user,
            ERC7683Permit2Lib.hashOrder(order, ERC7683Permit2Lib.hashOrderData(acrossOrderData)), // witness data hash
            ERC7683Permit2Lib.PERMIT2_ORDER_TYPE, // witness data type string
            signature
        );
    }

    function _callDeposit(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint256 depositNonce,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityPeriod,
        bytes memory message
    ) internal virtual;

    function _destinationSettler(uint256 chainId) internal view virtual returns (address);
}
