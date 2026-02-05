// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title CounterfactualDeposit
 * @notice Minimal proxy contract for counterfactual deposits with immutable route parameters
 * @dev This contract stores deposit route parameters as immutables and delegates all calls to the executor
 * Immutables are cheaper than storage (no SLOAD) and are embedded in the bytecode
 */
contract CounterfactualDeposit {
    /// @notice Factory contract that deployed this instance
    address public immutable factory;

    /// @notice SpokePool contract to execute deposits on
    address public immutable spokePool;

    /// @notice Input token address (bytes32 for cross-chain compatibility)
    bytes32 public immutable inputToken;

    /// @notice Output token address on destination chain
    bytes32 public immutable outputToken;

    /// @notice Destination chain ID
    uint256 public immutable destinationChainId;

    /// @notice Recipient address on destination chain (bytes32 for cross-chain compatibility)
    bytes32 public immutable recipient;

    /**
     * @notice Constructs the deposit contract with immutable parameters
     * @param _factory Factory contract address
     * @param _spokePool SpokePool contract address
     * @param _inputToken Input token address
     * @param _outputToken Output token address
     * @param _destinationChainId Destination chain ID
     * @param _recipient Recipient address on destination chain
     */
    constructor(
        address _factory,
        address _spokePool,
        bytes32 _inputToken,
        bytes32 _outputToken,
        uint256 _destinationChainId,
        bytes32 _recipient
    ) {
        factory = _factory;
        spokePool = _spokePool;
        inputToken = _inputToken;
        outputToken = _outputToken;
        destinationChainId = _destinationChainId;
        recipient = _recipient;
    }

    /**
     * @notice Fallback function that delegates all calls to the executor
     * @dev Uses delegatecall to execute in the context of this contract
     * Appends immutable parameters to calldata so executor can read them
     */
    fallback() external {
        address executor = ICounterfactualDepositFactory(factory).executor();

        // Store immutables in memory to pass via calldata
        address _factory = factory;
        address _spokePool = spokePool;
        bytes32 _inputToken = inputToken;
        bytes32 _outputToken = outputToken;
        uint256 _destinationChainId = destinationChainId;
        bytes32 _recipient = recipient;

        assembly {
            // Calculate total size: original calldata + 6 parameters (192 bytes)
            let totalSize := add(calldatasize(), 192)

            // Allocate memory for the extended calldata
            let ptr := mload(0x40)

            // Copy original calldata
            calldatacopy(ptr, 0, calldatasize())

            // Append immutable parameters
            let offset := add(ptr, calldatasize())
            mstore(offset, _factory)
            mstore(add(offset, 32), _spokePool)
            mstore(add(offset, 64), _inputToken)
            mstore(add(offset, 96), _outputToken)
            mstore(add(offset, 128), _destinationChainId)
            mstore(add(offset, 160), _recipient)

            // Delegatecall to executor with extended calldata
            let result := delegatecall(gas(), executor, ptr, totalSize, 0, 0)

            // Copy return data
            returndatacopy(0, 0, returndatasize())

            // Return or revert
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }
}

/**
 * @notice Minimal interface to get executor address from factory
 */
interface ICounterfactualDepositFactory {
    function executor() external view returns (address);
}
