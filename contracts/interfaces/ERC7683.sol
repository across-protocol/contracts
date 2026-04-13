// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

// @dev Deprecated: This ERC-7683 interface is from a previous version of the standard.
// A new version of ERC-7683 is being developed and will replace this interface.

/// @title IDestinationSettler
/// @notice Standard interface for settlement contracts on the destination chain
interface IDestinationSettler {
    /// @notice Fills a single leg of a particular order on the destination chain
    /// @param orderId Unique order identifier for this order
    /// @param originData Data emitted on the origin to parameterize the fill
    /// @param fillerData Data provided by the filler to inform the fill or express their preferences
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external;
}

/// @dev Deprecated: See note above.
struct AcrossDestinationFillerData {
    uint256 repaymentChainId;
}
