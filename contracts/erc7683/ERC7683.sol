// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @title GaslessCrossChainOrder CrossChainOrder type
/// @notice Standard order struct to be signed by users, disseminated to fillers, and submitted to origin settler contracts
struct GaslessCrossChainOrder {
    /// @dev The contract address that the order is meant to be settled by.
    /// Fillers send this order to this contract address on the origin chain
    address originSettler;
    /// @dev The address of the user who is initiating the swap,
    /// whose input tokens will be taken and escrowed
    address user;
    /// @dev Nonce to be used as replay protection for the order
    uint256 nonce;
    /// @dev The chainId of the origin chain
    uint256 originChainId;
    /// @dev The timestamp by which the order must be opened
    uint32 openDeadline;
    /// @dev The timestamp by which the order must be filled on the destination chain
    uint32 fillDeadline;
    /// @dev Type identifier for the order data. This is an EIP-712 typehash.
    bytes32 orderDataType;
    /// @dev Arbitrary implementation-specific data
    /// Can be used to define tokens, amounts, destination chains, fees, settlement parameters,
    /// or any other order-type specific information
    bytes orderData;
}

/// @title OnchainCrossChainOrder CrossChainOrder type
/// @notice Standard order struct for user-opened orders, where the user is the msg.sender.
struct OnchainCrossChainOrder {
    /// @dev The timestamp by which the order must be filled on the destination chain
    uint32 fillDeadline;
    /// @dev Type identifier for the order data. This is an EIP-712 typehash.
    bytes32 orderDataType;
    /// @dev Arbitrary implementation-specific data
    /// Can be used to define tokens, amounts, destination chains, fees, settlement parameters,
    /// or any other order-type specific information
    bytes orderData;
}

/// @title ResolvedCrossChainOrder type
/// @notice An implementation-generic representation of an order intended for filler consumption
/// @dev Defines all requirements for filling an order by unbundling the implementation-specific orderData.
/// @dev Intended to improve integration generalization by allowing fillers to compute the exact input and output information of any order
struct ResolvedCrossChainOrder {
    /// @dev The address of the user who is initiating the transfer
    address user;
    /// @dev The chainId of the origin chain
    uint256 originChainId;
    /// @dev The timestamp by which the order must be opened
    uint32 openDeadline;
    /// @dev The timestamp by which the order must be filled on the destination chain(s)
    uint32 fillDeadline;
    /// @dev The unique identifier for this order within this settlement system
    bytes32 orderId;
    /// @dev The max outputs that the filler will send. It's possible the actual amount depends on the state of the destination
    ///      chain (destination dutch auction, for instance), so these outputs should be considered a cap on filler liabilities.
    Output[] maxSpent;
    /// @dev The minimum outputs that must to be given to the filler as part of order settlement. Similar to maxSpent, it's possible
    ///      that special order types may not be able to guarantee the exact amount at open time, so this should be considered
    ///      a floor on filler receipts.
    Output[] minReceived;
    /// @dev Each instruction in this array is parameterizes a single leg of the fill. This provides the filler with the information
    ///      necessary to perform the fill on the destination(s).
    FillInstruction[] fillInstructions;
}

/// @notice Tokens that must be receive for a valid order fulfillment
struct Output {
    /// @dev The address of the ERC20 token on the destination chain
    /// @dev address(0) used as a sentinel for the native token
    bytes32 token;
    /// @dev The amount of the token to be sent
    uint256 amount;
    /// @dev The address to receive the output tokens
    bytes32 recipient;
    /// @dev The destination chain for this output
    uint256 chainId;
}

/// @title FillInstruction type
/// @notice Instructions to parameterize each leg of the fill
/// @dev Provides all the origin-generated information required to produce a valid fill leg
struct FillInstruction {
    /// @dev The contract address that the order is meant to be settled by
    uint64 destinationChainId;
    /// @dev The contract address that the order is meant to be filled on
    bytes32 destinationSettler;
    /// @dev The data generated on the origin chain needed by the destinationSettler to process the fill
    bytes originData;
}

/// @title IOriginSettler
/// @notice Standard interface for settlement contracts on the origin chain
interface IOriginSettler {
    /// @notice Signals that an order has been opened
    /// @param orderId a unique order identifier within this settlement system
    /// @param resolvedOrder resolved order that would be returned by resolve if called instead of Open
    event Open(bytes32 indexed orderId, ResolvedCrossChainOrder resolvedOrder);

    /// @notice Opens a gasless cross-chain order on behalf of a user.
    /// @dev To be called by the filler.
    /// @dev This method must emit the Open event
    /// @param order The GaslessCrossChainOrder definition
    /// @param signature The user's signature over the order
    /// @param originFillerData Any filler-defined data required by the settler
    function openFor(
        GaslessCrossChainOrder calldata order,
        bytes calldata signature,
        bytes calldata originFillerData
    ) external;

    /// @notice Opens a cross-chain order
    /// @dev To be called by the user
    /// @dev This method must emit the Open event
    /// @param order The OnchainCrossChainOrder definition
    function open(OnchainCrossChainOrder calldata order) external;

    /// @notice Resolves a specific GaslessCrossChainOrder into a generic ResolvedCrossChainOrder
    /// @dev Intended to improve standardized integration of various order types and settlement contracts
    /// @param order The GaslessCrossChainOrder definition
    /// @param originFillerData Any filler-defined data required by the settler
    /// @return ResolvedCrossChainOrder hydrated order data including the inputs and outputs of the order
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        external
        view
        returns (ResolvedCrossChainOrder memory);

    /// @notice Resolves a specific OnchainCrossChainOrder into a generic ResolvedCrossChainOrder
    /// @dev Intended to improve standardized integration of various order types and settlement contracts
    /// @param order The OnchainCrossChainOrder definition
    /// @return ResolvedCrossChainOrder hydrated order data including the inputs and outputs of the order
    function resolve(OnchainCrossChainOrder calldata order) external view returns (ResolvedCrossChainOrder memory);
}

/// @title IDestinationSettler
/// @notice Standard interface for settlement contracts on the destination chain
interface IDestinationSettler {
    /// @notice Fills a single leg of a particular order on the destination chain
    /// @param orderId Unique order identifier for this order
    /// @param originData Data emitted on the origin to parameterize the fill
    /// @param fillerData Data provided by the filler to inform the fill or express their preferences
    function fill(
        bytes32 orderId,
        bytes calldata originData,
        bytes calldata fillerData
    ) external;
}
