// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ECDSA } from "@openzeppelin/contracts-v4/utils/cryptography/ECDSA.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "./CounterfactualDeposit.sol";
import { CounterfactualDepositExecutor } from "./CounterfactualDepositExecutor.sol";

/**
 * @title CounterfactualDepositFactory
 * @notice Factory for deploying and managing counterfactual deposit addresses
 * @dev Uses CREATE2 for deterministic address generation and ECDSA for quote verification
 */
contract CounterfactualDepositFactory is ICounterfactualDepositFactory {
    /// @notice SpokePool contract address (immutable per deployment)
    address public immutable spokePool;

    /// @notice Executor implementation contract (immutable singleton)
    address public immutable executor;

    /// @notice Current admin address (can update quoteSigner and admin)
    address public admin;

    /// @notice Current quote signer address (signs deposit quotes)
    address public quoteSigner;

    /**
     * @notice Constructs the factory with immutable addresses
     * @param _spokePool SpokePool contract address
     * @param _executor Executor implementation address
     * @param _admin Initial admin address
     * @param _quoteSigner Initial quote signer address
     */
    constructor(address _spokePool, address _executor, address _admin, address _quoteSigner) {
        spokePool = _spokePool;
        executor = _executor;
        admin = _admin;
        quoteSigner = _quoteSigner;
    }

    /**
     * @notice Predicts the address of a counterfactual deposit contract
     * @param inputToken Input token address
     * @param outputToken Output token address
     * @param destinationChainId Destination chain ID
     * @param recipient Recipient address on destination chain
     * @param salt Unique salt for address generation
     * @return Predicted address
     */
    function predictDepositAddress(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes32 salt
    ) public view returns (address) {
        // Compute creation code hash for CREATE2
        bytes32 creationCodeHash = keccak256(
            abi.encodePacked(
                type(CounterfactualDeposit).creationCode,
                abi.encode(address(this), spokePool, inputToken, outputToken, destinationChainId, recipient)
            )
        );

        // Compute CREATE2 address
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, creationCodeHash)))));
    }

    /**
     * @notice Deploys a counterfactual deposit contract
     * @param inputToken Input token address
     * @param outputToken Output token address
     * @param destinationChainId Destination chain ID
     * @param recipient Recipient address on destination chain
     * @param salt Unique salt for address generation
     * @return depositAddress Address of deployed contract
     */
    function deploy(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes32 salt
    ) public returns (address depositAddress) {
        // Deploy via CREATE2
        depositAddress = address(
            new CounterfactualDeposit{ salt: salt }(
                address(this),
                spokePool,
                inputToken,
                outputToken,
                destinationChainId,
                recipient
            )
        );

        emit DepositAddressCreated(depositAddress, inputToken, outputToken, destinationChainId, recipient, salt);
    }

    /**
     * @notice Deploys and executes a deposit in one transaction
     * @param inputToken Input token address
     * @param outputToken Output token address
     * @param destinationChainId Destination chain ID
     * @param recipient Recipient address on destination chain
     * @param salt Unique salt for address generation
     * @param quote Signed deposit quote
     * @param signature Signature from authorized quoteSigner
     * @return depositAddress Address of deposit contract
     */
    function deployAndExecute(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes32 recipient,
        bytes32 salt,
        DepositQuote calldata quote,
        bytes calldata signature
    ) external returns (address depositAddress) {
        // Try to deploy (will revert if already deployed, which we catch)
        try this.deploy(inputToken, outputToken, destinationChainId, recipient, salt) returns (address addr) {
            depositAddress = addr;
        } catch {
            // Already deployed, predict the address
            depositAddress = predictDepositAddress(inputToken, outputToken, destinationChainId, recipient, salt);
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
     * @notice Verifies a deposit quote signature
     * @param quote Deposit quote to verify
     * @param signature Signature to verify
     * @return True if signature is valid
     */
    function verifyQuote(DepositQuote calldata quote, bytes calldata signature) public view returns (bool) {
        // Compute message hash
        bytes32 messageHash = keccak256(
            abi.encode(
                quote.depositAddress,
                quote.deadline,
                quote.inputAmount,
                quote.outputAmount,
                quote.quoteTimestamp,
                quote.fillDeadline,
                quote.exclusivityParameter,
                quote.exclusiveRelayer,
                keccak256(quote.message)
            )
        );

        // Add Ethereum signed message prefix
        bytes32 ethSignedMessageHash = ECDSA.toEthSignedMessageHash(messageHash);

        // Recover signer and compare
        address recoveredSigner = ECDSA.recover(ethSignedMessageHash, signature);
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
}
