// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../external/interfaces/IPermit2.sol";
import "../interfaces/V3SpokePoolInterface.sol";

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Input, Output, CrossChainOrder, ResolvedCrossChainOrder, ISettlementContract } from "./ERC7683.sol";
import { AcrossOrderData, AcrossFillerData, ERC7683Permit2Lib } from "./ERC7683Across.sol";

/**
 * @notice ERC7683OrderDepositor processes an external order type and translates it into an AcrossV3 deposit.
 * @dev This contract is abstract because it is intended to be usable by a contract that can accept the deposit
 * as well as one that sends the deposit to another contract.
 */
abstract contract ERC7683OrderDepositor is ISettlementContract {
    error WrongSettlementContract();
    error WrongChainId();

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
     * @notice Initiate the order.
     * @dev This will pull in the user's funds and make the order available to be filled.
     * @param order the ERC7683 compliant order.
     * @param signature signature for the EIP-712 compliant order type.
     * @param fillerData Across-specific fillerData.
     */
    function initiate(
        CrossChainOrder memory order,
        bytes memory signature,
        bytes memory fillerData
    ) external {
        // Ensure that order was intended to be settled by Across.
        if (order.settlementContract != address(this)) {
            revert WrongSettlementContract();
        }

        if (order.originChainId != block.chainid) {
            revert WrongChainId();
        }

        // Extract Across-specific params.
        (AcrossOrderData memory acrossOrderData, AcrossFillerData memory acrossFillerData) = decode(
            order.orderData,
            fillerData
        );

        // Verify Permit2 signature and pull user funds into this contract
        _processPermit2Order(order, acrossOrderData, signature);

        _callDeposit(
            order.swapper,
            acrossOrderData.recipient,
            acrossOrderData.inputToken,
            acrossOrderData.outputToken,
            acrossOrderData.inputAmount,
            acrossOrderData.outputAmount,
            acrossOrderData.destinationChainId,
            acrossFillerData.exclusiveRelayer,
            // Note: simplifying assumption to avoid quote timestamps that cause orders to expire before the deadline.
            SafeCast.toUint32(order.initiateDeadline - QUOTE_BEFORE_DEADLINE),
            order.fillDeadline,
            acrossOrderData.exclusivityDeadline,
            acrossOrderData.message
        );
    }

    /**
     * @notice Constructs a ResolvedOrder from a CrossChainOrder and fillerData.
     * @param order the ERC7683 compliant order.
     * @param fillerData Across-specific fillerData.
     */
    function resolve(CrossChainOrder memory order, bytes memory fillerData)
        external
        view
        returns (ResolvedCrossChainOrder memory resolvedOrder)
    {
        if (order.settlementContract != address(this)) {
            revert WrongSettlementContract();
        }

        if (order.originChainId != block.chainid) {
            revert WrongChainId();
        }

        (AcrossOrderData memory acrossOrderData, AcrossFillerData memory acrossFillerData) = decode(
            order.orderData,
            fillerData
        );
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
            recipient: acrossFillerData.exclusiveRelayer,
            chainId: SafeCast.toUint32(block.chainid)
        });

        resolvedOrder = ResolvedCrossChainOrder({
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

    /**
     * @notice Decodes the Across specific orderData and fillerData into descriptive types.
     * @param orderData the orderData field of the ERC7683 compliant order.
     * @param fillerData Across-specific fillerData.
     * @return acrossOrderData decoded AcrossOrderData.
     * @return acrossFillerData decoded AcrossFillerData.
     */
    function decode(bytes memory orderData, bytes memory fillerData)
        public
        pure
        returns (AcrossOrderData memory, AcrossFillerData memory)
    {
        return (abi.decode(orderData, (AcrossOrderData)), abi.decode(fillerData, (AcrossFillerData)));
    }

    function _processPermit2Order(
        CrossChainOrder memory order,
        AcrossOrderData memory acrossOrderData,
        bytes memory signature
    ) internal {
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({
                token: acrossOrderData.inputToken,
                amount: acrossOrderData.inputAmount
            }),
            nonce: order.nonce,
            deadline: order.initiateDeadline
        });

        IPermit2.SignatureTransferDetails memory signatureTransferDetails = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: acrossOrderData.inputAmount
        });

        // Pull user funds.
        PERMIT2.permitWitnessTransferFrom(
            permit,
            signatureTransferDetails,
            order.swapper,
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
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes memory message
    ) internal virtual;
}
