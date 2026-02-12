// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";
import { CounterfactualDepositExecutor } from "./CounterfactualDepositExecutor.sol";

/**
 * @title CounterfactualDepositFactory
 * @notice Factory for deploying and managing counterfactual deposit addresses that deposit via SponsoredCCTP
 * @dev Uses CREATE2 for deterministic address generation. Quote signature verification is delegated
 *      to SponsoredCCTPSrcPeriphery — this factory only handles clone deployment and admin management.
 */
contract CounterfactualDepositFactory is ICounterfactualDepositFactory {
    /// @notice Current admin address (can withdraw from clones and update admin)
    address public admin;

    constructor(address _admin) {
        admin = _admin;
    }

    /**
     * @notice Predicts the address of a counterfactual deposit contract
     * @param executor Executor implementation address
     * @param params CCTP route parameters (stored as clone immutable args)
     * @param salt Unique salt for address generation
     * @return Predicted address
     */
    function predictDepositAddress(
        address executor,
        CCTPRouteParams memory params,
        bytes32 salt
    ) public view returns (address) {
        return Clones.predictDeterministicAddressWithImmutableArgs(executor, abi.encode(params), salt);
    }

    /**
     * @notice Deploys a counterfactual deposit contract
     * @param executor Executor implementation address
     * @param params CCTP route parameters (stored as clone immutable args)
     * @param salt Unique salt for address generation
     * @return depositAddress Address of deployed contract
     */
    function deploy(
        address executor,
        CCTPRouteParams memory params,
        bytes32 salt
    ) public returns (address depositAddress) {
        depositAddress = Clones.cloneDeterministicWithImmutableArgs(executor, abi.encode(params), salt);
        emit DepositAddressCreated(
            depositAddress,
            params.burnToken,
            params.destinationDomain,
            params.finalRecipient,
            salt
        );
    }

    /**
     * @notice Deploys and executes a deposit in one transaction
     * @param executor Executor implementation address
     * @param params CCTP route parameters (stored as clone immutable args)
     * @param salt Unique salt for address generation
     * @param amount Amount of burnToken to deposit
     * @param nonce Unique nonce for SponsoredCCTP replay protection
     * @param deadline Timestamp after which the quote expires
     * @param signature Signature from SponsoredCCTP quote signer
     * @return depositAddress Address of deposit contract
     */
    function deployAndExecute(
        address executor,
        CCTPRouteParams memory params,
        bytes32 salt,
        uint256 amount,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (address depositAddress) {
        try this.deploy(executor, params, salt) returns (address addr) {
            depositAddress = addr;
        } catch {
            depositAddress = predictDepositAddress(executor, params, salt);
        }
        CounterfactualDepositExecutor(depositAddress).executeDeposit(amount, nonce, deadline, signature);
    }

    /**
     * @notice Executes a deposit on an existing contract
     * @param depositAddress Address of existing deposit contract
     * @param amount Amount of burnToken to deposit
     * @param nonce Unique nonce for SponsoredCCTP replay protection
     * @param deadline Timestamp after which the quote expires
     * @param signature Signature from SponsoredCCTP quote signer
     */
    function executeOnExisting(
        address depositAddress,
        uint256 amount,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        CounterfactualDepositExecutor(depositAddress).executeDeposit(amount, nonce, deadline, signature);
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
