// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Permit2OrderLib.sol";
import "../external/interfaces/IPermit2.sol";
import "../interfaces/V3SpokePoolInterface.sol";

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./Permit2OrderLib.sol";

/// @title CrossChainOrder type
/// @notice Standard order struct to be signed by swappers, disseminated to fillers, and submitted to settlement contracts
struct CrossChainOrder {
    /// @dev The contract address that the order is meant to be settled by.
    /// Fillers send this order to this contract address on the origin chain
    address settlementContract;
    /// @dev The address of the user who is initiating the swap,
    /// whose input tokens will be taken and escrowed
    address swapper;
    /// @dev Nonce to be used as replay protection for the order
    uint256 nonce;
    /// @dev The chainId of the origin chain
    uint32 originChainId;
    /// @dev The timestamp by which the order must be initiated
    uint32 initiateDeadline;
    /// @dev The timestamp by which the order must be filled on the destination chain
    uint32 fillDeadline;
    /// @dev Arbitrary implementation-specific data
    /// Can be used to define tokens, amounts, destination chains, fees, settlement parameters,
    /// or any other order-type specific information
    bytes orderData;
}

/// @title ResolvedCrossChainOrder type
/// @notice An implementation-generic representation of an order
/// @dev Defines all requirements for filling an order by unbundling the implementation-specific orderData.
/// @dev Intended to improve integration generalization by allowing fillers to compute the exact input and output information of any order
struct ResolvedCrossChainOrder {
    /// @dev The contract address that the order is meant to be settled by.
    address settlementContract;
    /// @dev The address of the user who is initiating the swap
    address swapper;
    /// @dev Nonce to be used as replay protection for the order
    uint256 nonce;
    /// @dev The chainId of the origin chain
    uint32 originChainId;
    /// @dev The timestamp by which the order must be initiated
    uint32 initiateDeadline;
    /// @dev The timestamp by which the order must be filled on the destination chain(s)
    uint32 fillDeadline;
    /// @dev The inputs to be taken from the swapper as part of order initiation
    Input[] swapperInputs;
    /// @dev The outputs to be given to the swapper as part of order fulfillment
    Output[] swapperOutputs;
    /// @dev The outputs to be given to the filler as part of order settlement
    Output[] fillerOutputs;
}

/// @notice Tokens sent by the swapper as inputs to the order
struct Input {
    /// @dev The address of the ERC20 token on the origin chain
    address token;
    /// @dev The amount of the token to be sent
    uint256 amount;
}

/// @notice Tokens that must be receive for a valid order fulfillment
struct Output {
    /// @dev The address of the ERC20 token on the destination chain
    /// @dev address(0) used as a sentinel for the native token
    address token;
    /// @dev The amount of the token to be sent
    uint256 amount;
    /// @dev The address to receive the output tokens
    address recipient;
    /// @dev The destination chain for this output
    uint32 chainId;
}

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

/// @title ISettlementContract
/// @notice Standard interface for settlement contracts
interface ISettlementContract {
    /// @notice Initiates the settlement of a cross-chain order
    /// @dev To be called by the filler
    /// @param order The CrossChainOrder definition
    /// @param signature The swapper's signature over the order
    /// @param fillerData Any filler-defined data required by the settler
    function initiate(
        CrossChainOrder memory order,
        bytes memory signature,
        bytes memory fillerData
    ) external;

    /// @notice Resolves a specific CrossChainOrder into a generic ResolvedCrossChainOrder
    /// @dev Intended to improve standardized integration of various order types and settlement contracts
    /// @param order The CrossChainOrder definition
    /// @param fillerData Any filler-defined data required by the settler
    /// @return ResolvedCrossChainOrder hydrated order data including the inputs and outputs of the order
    function resolve(CrossChainOrder memory order, bytes memory fillerData)
        external
        view
        returns (ResolvedCrossChainOrder memory);
}

/**
 * @notice Permit2Depositor processes an external order type and translates it into an AcrossV3 deposit.
 */
contract ERC7683OrderDepositor is ISettlementContract {
    using SafeERC20 for IERC20;

    // Unique Across nonce
    uint256 depositId;

    // SpokePool that this contract can deposit to.
    V3SpokePoolInterface public immutable SPOKE_POOL;

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
        SPOKE_POOL.depositV3(
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
}
