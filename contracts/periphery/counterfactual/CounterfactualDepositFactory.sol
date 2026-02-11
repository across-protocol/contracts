// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ECDSA } from "@openzeppelin/contracts-v4/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts-v4/utils/cryptography/EIP712.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";
import { CounterfactualDepositExecutor } from "./CounterfactualDepositExecutor.sol";

/**
 * @title CounterfactualDepositFactory
 * @notice Factory for deploying and managing counterfactual deposit addresses
 * @dev Uses CREATE2 for deterministic address generation and EIP-712 for quote verification
 */
contract CounterfactualDepositFactory is ICounterfactualDepositFactory, EIP712 {
    /// @notice EIP-712 typehash for DepositQuote struct
    bytes32 public constant DEPOSIT_QUOTE_TYPEHASH =
        keccak256(
            "DepositQuote(address depositAddress,uint256 deadline,uint256 inputAmount,uint256 outputAmount,uint32 quoteTimestamp,uint32 fillDeadline,uint32 exclusivityParameter,bytes32 exclusiveRelayer)"
        );

    /// @notice SpokePool contract address (immutable per deployment)
    address public immutable spokePool;

    /// @notice Current admin address (can update quoteSigner and admin)
    address public admin;

    /// @notice Current quote signer address (signs deposit quotes)
    address public quoteSigner;

    /**
     * @notice Constructs the factory
     * @param _spokePool SpokePool contract address
     * @param _admin Initial admin address
     * @param _quoteSigner Initial quote signer address
     */
    constructor(address _spokePool, address _admin, address _quoteSigner) EIP712("Across Counterfactual Deposit", "1") {
        spokePool = _spokePool;
        admin = _admin;
        quoteSigner = _quoteSigner;
    }

    /**
     * @notice Predicts the address of a counterfactual deposit contract
     * @param executor Executor implementation address
     * @param inputToken Input token address
     * @param outputToken Output token address
     * @param destinationChainId Destination chain ID
     * @param recipient Recipient address on destination chain
     * @param message Message to forward to recipient
     * @param maxGasFee Maximum absolute fee in wei
     * @param maxCapitalFee Maximum fee as percentage in basis points
     * @param salt Unique salt for address generation
     * @return Predicted address
     */
    function predictDepositAddress(
        address executor,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes memory message,
        uint256 maxGasFee,
        uint256 maxCapitalFee,
        bytes32 salt
    ) public view returns (address) {
        bytes memory args = _encodeArgs(
            inputToken,
            outputToken,
            destinationChainId,
            recipient,
            maxGasFee,
            maxCapitalFee,
            message
        );
        return Clones.predictDeterministicAddressWithImmutableArgs(executor, args, salt);
    }

    /**
     * @notice Deploys a counterfactual deposit contract
     * @param executor Executor implementation address
     * @param inputToken Input token address
     * @param outputToken Output token address
     * @param destinationChainId Destination chain ID
     * @param recipient Recipient address on destination chain
     * @param message Message to forward to recipient
     * @param maxGasFee Maximum absolute fee in wei
     * @param maxCapitalFee Maximum fee as percentage in basis points
     * @param salt Unique salt for address generation
     * @return depositAddress Address of deployed contract
     */
    function deploy(
        address executor,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes memory message,
        uint256 maxGasFee,
        uint256 maxCapitalFee,
        bytes32 salt
    ) public returns (address depositAddress) {
        bytes memory args = _encodeArgs(
            inputToken,
            outputToken,
            destinationChainId,
            recipient,
            maxGasFee,
            maxCapitalFee,
            message
        );
        depositAddress = Clones.cloneDeterministicWithImmutableArgs(executor, args, salt);

        emit DepositAddressCreated(depositAddress, inputToken, outputToken, destinationChainId, recipient, salt);
    }

    /**
     * @notice Deploys and executes a deposit in one transaction
     * @param executor Executor implementation address
     * @param inputToken Input token address
     * @param outputToken Output token address
     * @param destinationChainId Destination chain ID
     * @param recipient Recipient address on destination chain
     * @param message Message to forward to recipient
     * @param maxGasFee Maximum absolute fee in wei
     * @param maxCapitalFee Maximum fee as percentage in basis points
     * @param salt Unique salt for address generation
     * @param quote Signed deposit quote
     * @param signature Signature from authorized quoteSigner
     * @return depositAddress Address of deposit contract
     */
    function deployAndExecute(
        address executor,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes memory message,
        uint256 maxGasFee,
        uint256 maxCapitalFee,
        bytes32 salt,
        DepositQuote calldata quote,
        bytes calldata signature
    ) external returns (address depositAddress) {
        // Try to deploy (will revert if already deployed, which we catch)
        try
            this.deploy(
                executor,
                inputToken,
                outputToken,
                destinationChainId,
                recipient,
                message,
                maxGasFee,
                maxCapitalFee,
                salt
            )
        returns (address addr) {
            depositAddress = addr;
        } catch {
            // Already deployed, predict the address
            depositAddress = predictDepositAddress(
                executor,
                inputToken,
                outputToken,
                destinationChainId,
                recipient,
                message,
                maxGasFee,
                maxCapitalFee,
                salt
            );
        }

        // Execute deposit on the deployed contract
        CounterfactualDepositExecutor(depositAddress).executeDeposit(quote, signature);
    }

    /**
     * @notice Executes a deposit on an existing contract
     * @param depositAddress Address of existing deposit contract
     * @param quote Signed deposit quote
     * @param signature Signature from authorized quoteSigner
     */
    function executeOnExisting(address depositAddress, DepositQuote calldata quote, bytes calldata signature) external {
        CounterfactualDepositExecutor(depositAddress).executeDeposit(quote, signature);
    }

    /**
     * @notice Verifies a deposit quote signature using EIP-712
     * @param quote Deposit quote to verify
     * @param signature Signature to verify
     * @return True if signature is valid
     * @dev message is not part of quote (it's immutable in proxy), so not included in signature
     */
    function verifyQuote(DepositQuote calldata quote, bytes calldata signature) public view returns (bool) {
        // Hash the struct data
        bytes32 structHash = keccak256(
            abi.encode(
                DEPOSIT_QUOTE_TYPEHASH,
                quote.depositAddress,
                quote.deadline,
                quote.inputAmount,
                quote.outputAmount,
                quote.quoteTimestamp,
                quote.fillDeadline,
                quote.exclusivityParameter,
                quote.exclusiveRelayer
            )
        );

        // Compute EIP-712 digest using OpenZeppelin's helper
        bytes32 digest = _hashTypedDataV4(structHash);

        // Recover signer and compare
        address recoveredSigner = ECDSA.recover(digest, signature);
        return recoveredSigner == quoteSigner;
    }

    /**
     * @notice Updates the quote signer address
     * @param newSigner New quote signer address
     */
    function setQuoteSigner(address newSigner) external {
        if (msg.sender != admin) revert Unauthorized();
        address oldSigner = quoteSigner;
        quoteSigner = newSigner;
        emit QuoteSignerUpdated(oldSigner, newSigner);
    }

    /**
     * @notice Updates the admin address
     * @param newAdmin New admin address
     */
    function setAdmin(address newAdmin) external {
        if (msg.sender != admin) revert Unauthorized();
        address oldAdmin = admin;
        admin = newAdmin;
        emit AdminUpdated(oldAdmin, newAdmin);
    }

    function _encodeArgs(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 recipient,
        uint256 maxGasFee,
        uint256 maxCapitalFee,
        bytes memory message
    ) private pure returns (bytes memory) {
        return abi.encode(inputToken, outputToken, destinationChainId, recipient, maxGasFee, maxCapitalFee, message);
    }
}
