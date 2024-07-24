// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @notice Tokens sent by the swapper as inputs to the order
struct Input {
    /// @dev The address of the ERC20 token on the origin chain
    address token;
    /// @dev The amount of the token to be sent
    uint256 amount;
}

/// @notice Tokens that must be received for a valid order fulfillment
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
