// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice SP1HeliosLightClient
/// https://github.com/succinctlabs/sp1-helios/blob/776337bf8b63bcf9beebad143e8981020dec2b52/contracts/src/SP1Helios.sol
interface IHelios {
    /// @notice Gets the value of a storage slot at a specific block
    function getStorageSlot(
        uint256 blockNumber,
        address contractAddress,
        bytes32 slot
    ) external view returns (bytes32);
}
