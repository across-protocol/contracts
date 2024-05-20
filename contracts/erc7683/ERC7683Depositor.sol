// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Permit2OrderLib.sol";
import "../external/interfaces/IPermit2.sol";
import "../interfaces/V3SpokePoolInterface.sol";

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./Permit2OrderLib.sol";

import { CrossChainOrder, ResolvedCrossChainOrder, ISettlementContract } from "./ERC7683.sol";

// Data unique to every CrossChainOrder settled on Across
struct AcrossOrderData {
    address inputToken;
    uint256 inputAmount;
    address outputToken;
    uint256 outputAmount;
    uint32 destinationChainId;
    address recipient;
    uint32 exclusivityDeadline;
    address exclusiveRelayer;
    bytes message;
}

// Data unique to every attempted order fulfillment
struct AcrossFillerData {
    // Filler can choose where they want to be repaid
    uint32 repaymentChainId;
}

/**
 * @notice Permit2Depositor processes an external order type and translates it into an AcrossV3 deposit.
 */
abstract contract ERC7683OrderDepositor is ISettlementContract {
    using SafeERC20 for IERC20;

    // Permit2 contract for this network
    IPermit2 public immutable PERMIT2;

    // quoteBeforeDeadline is subtracted from the deadline to get the quote timestamp.
    // This is a somewhat arbitrary conversion, but order creators need some way to precompute the quote timestamp.
    uint256 public immutable QUOTE_BEFORE_DEADLINE;

    /**
     * @notice Construct the Permit2Depositor.
     * @param _spokePool SpokePool that this contract can deposit to.
     * @param _permit2 Permit2 contract
     * @param _quoteBeforeDeadline quoteBeforeDeadline is subtracted from the deadline to get the quote timestamp.
     */
    constructor(
        V3SpokePoolInterface _spokePool,
        IPermit2 _permit2,
        uint256 _quoteBeforeDeadline
    ) {
        SPOKE_POOL = _spokePool;
        PERMIT2 = _permit2;
        QUOTE_BEFORE_DEADLINE = _quoteBeforeDeadline;
    }

    function initiate(
        CrossChainOrder memory order,
        bytes memory signature,
        bytes memory fillerData
    ) external {
        // Ensure that order was intended to be settled by Across.
        require(order.settlementContract == address(this));
        require(order.originChainId == block.chainid);

        // Extract Across-specific params.
        (AcrossOrderData memory acrossOrderData, ResolvedCrossChainOrder memory resolvedOrder, ) = _resolve(
            order,
            fillerData
        );

        // Require that the order has a single input and output.
        require(
            resolvedOrder.swapperInputs.length == 1 &&
                resolvedOrder.swapperOutputs.length == 1 &&
                resolvedOrder.fillerOutputs.length == 1
        );

        // Verify Permit2 signature and pull user funds into this contract
        _processPermit2Order(PERMIT2, order, resolvedOrder, signature);

        IERC20(resolvedOrder.swapperInputs[0].token).safeIncreaseAllowance(
            address(SPOKE_POOL),
            resolvedOrder.swapperInputs[0].amount
        );

        _callDeposit(
            order.swapper,
            resolvedOrder.swapperOutputs[0].recipient,
            resolvedOrder.swapperInputs[0].token,
            resolvedOrder.swapperOutputs[0].token,
            resolvedOrder.swapperInputs[0].amount,
            resolvedOrder.swapperOutputs[0].amount,
            resolvedOrder.swapperOutputs[0].chainId,
            acrossOrderData.exclusiveRelayer,
            SafeCast.toUint32(order.initiateDeadline - QUOTE_BEFORE_DEADLINE),
            order.fillDeadline,
            // The entire fill period is exclusive.
            order.fillDeadline,
            ""
        );
    }

    function resolve(CrossChainOrder memory order, bytes memory fillerData)
        external
        view
        returns (ResolvedCrossChainOrder memory resolvedOrder)
    {
        (, resolvedOrder, ) = _resolve(order, fillerData);
    }

    function _resolve(CrossChainOrder memory order, bytes memory fillerData)
        internal
        view
        returns (
            AcrossOrderData memory acrossOrderData,
            ResolvedCrossChainOrder memory resolvedCrossChainOrder,
            AcrossFillerData memory acrossFillerData
        )
    {
        // Extract Across-specific params.
        acrossOrderData = abi.decode(order.orderData, (AcrossOrderData));
        acrossFillerData = abi.decode(fillerData, (AcrossFillerData));

        Input[] memory inputs = new Input[](1);
        inputs[0] = Input({ token: acrossOrderData.inputToken, amount: acrossOrderData.inputAmount });
        Output[] memory outputs = new Output[](1);
        outputs[0] = Output({
            token: acrossOrderData.outputToken,
            amount: acrossOrderData.outputAmount,
            recipient: acrossOrderData.recipient,
            chainId: acrossOrderData.destinationChainId
        });
        // We assume that filler takes repayment on the origin chain in which case the filler output
        // will always be equal to the input amount. If the filler requests repayment somewhere else then
        // the filler output will be equal to the input amount less a fee based on the chain they request
        // repayment on.
        Output[] memory fillerOutputs = new Output[](1);
        fillerOutputs[0] = Output({
            token: acrossOrderData.inputToken,
            amount: acrossOrderData.inputAmount,
            recipient: acrossOrderData.exclusiveRelayer,
            chainId: acrossFillerData.repaymentChainId
        });

        resolvedCrossChainOrder = ResolvedCrossChainOrder({
            settlementContract: address(this),
            swapper: order.swapper,
            nonce: order.nonce,
            originChainId: order.originChainId,
            initiateDeadline: order.initiateDeadline,
            fillDeadline: order.fillDeadline,
            swapperInputs: inputs,
            swapperOutputs: outputs,
            fillerOutputs: fillerOutputs
        });
    }

    function _processPermit2Order(
        IPermit2 permit2,
        CrossChainOrder memory order,
        ResolvedCrossChainOrder memory resolvedOrder,
        bytes memory signature
    ) internal {
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({
                token: resolvedOrder.swapperInputs[0].token,
                amount: resolvedOrder.swapperInputs[0].amount
            }),
            nonce: order.nonce,
            deadline: order.initiateDeadline
        });

        IPermit2.SignatureTransferDetails memory signatureTransferDetails = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: resolvedOrder.swapperInputs[0].amount
        });

        // Pull user funds.
        permit2.permitWitnessTransferFrom(
            permit,
            signatureTransferDetails,
            order.swapper,
            Permit2OrderLib.hashOrder(order), // witness data hash
            Permit2OrderLib.PERMIT2_ORDER_TYPE, // witness data type string
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
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes memory message
    ) internal;
}
