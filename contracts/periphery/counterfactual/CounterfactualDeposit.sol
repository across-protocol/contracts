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

    /// @notice Whether this deposit has a message (avoids storage read in common case)
    bool public immutable hasMessage;

    /// @notice Message to forward to recipient on destination chain (only read if hasMessage is true)
    bytes public message;

    /// @notice Maximum absolute fee (inputAmount - outputAmount) in wei that user will accept
    uint256 public immutable maxGasFee;

    /// @notice Maximum fee as percentage in basis points (10000 = 100%) that user will accept
    uint256 public immutable maxCapitalFee;

    /**
     * @notice Constructs the deposit contract with immutable parameters
     * @param _factory Factory contract address
     * @param _spokePool SpokePool contract address
     * @param _inputToken Input token address
     * @param _outputToken Output token address
     * @param _destinationChainId Destination chain ID
     * @param _recipient Recipient address on destination chain
     * @param _message Message to forward to recipient
     * @param _maxGasFee Maximum absolute fee in wei
     * @param _maxCapitalFee Maximum fee as percentage in basis points (10000 = 100%)
     */
    constructor(
        address _factory,
        address _spokePool,
        bytes32 _inputToken,
        bytes32 _outputToken,
        uint256 _destinationChainId,
        bytes32 _recipient,
        bytes memory _message,
        uint256 _maxGasFee,
        uint256 _maxCapitalFee
    ) {
        factory = _factory;
        spokePool = _spokePool;
        inputToken = _inputToken;
        outputToken = _outputToken;
        destinationChainId = _destinationChainId;
        recipient = _recipient;
        hasMessage = _message.length > 0;
        message = _message;
        maxGasFee = _maxGasFee;
        maxCapitalFee = _maxCapitalFee;
    }

    /**
     * @notice Fallback function that delegates all calls to the executor
     * @dev Uses delegatecall to execute in the context of this contract
     * Appends ABI-encoded route parameters + original calldata size to calldata
     * Format: [original calldata][ABI-encoded route params][uint256 original calldata size]
     * Note: factory and spokePool are immutable in executor; only route params passed via calldata
     * Optimization: Only reads message from storage if hasMessage is true
     */
    fallback() external {
        address executor = ICounterfactualDepositFactory(factory).executor();

        // ABI-encode route parameters (only read message from storage if needed)
        bytes memory routeParams;
        if (hasMessage) {
            routeParams = abi.encode(
                inputToken,
                outputToken,
                destinationChainId,
                recipient,
                message,
                maxGasFee,
                maxCapitalFee
            );
        } else {
            routeParams = abi.encode(
                inputToken,
                outputToken,
                destinationChainId,
                recipient,
                "",
                maxGasFee,
                maxCapitalFee
            );
        }

        assembly {
            // Get original calldata size
            let originalSize := calldatasize()

            // Get free memory pointer
            let ptr := mload(0x40)

            // Copy original calldata
            calldatacopy(ptr, 0, originalSize)

            // Append encoded route parameters
            let routeParamsPtr := add(routeParams, 0x20) // Skip length prefix
            let routeParamsLen := mload(routeParams)
            let offset := add(ptr, originalSize)

            // Copy route params
            for {
                let i := 0
            } lt(i, routeParamsLen) {
                i := add(i, 0x20)
            } {
                mstore(add(offset, i), mload(add(routeParamsPtr, i)))
            }

            // Append original calldata size at the very end (so executor knows where route params start)
            mstore(add(add(offset, routeParamsLen), 0), originalSize)

            // Calculate total size: original + route params + 32 bytes for size marker
            let totalSize := add(add(originalSize, routeParamsLen), 32)

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
