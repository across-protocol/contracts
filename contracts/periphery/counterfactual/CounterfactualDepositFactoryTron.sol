// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { TronClones } from "./TronClones.sol";
import { CounterfactualDepositFactory } from "./CounterfactualDepositFactory.sol";

/**
 * @title CounterfactualDepositFactoryTron
 * @notice Tron-compatible factory for deploying counterfactual deposit addresses via CREATE2.
 * @dev Tron's TVM uses 0x41 instead of 0xff as the CREATE2 address derivation prefix.
 *      OZ Clones deploys correctly (the create2 opcode natively uses 0x41 on Tron), but its
 *      address prediction hardcodes 0xff. This factory overrides predictDepositAddress to use
 *      TronClones with the correct 0x41 prefix. All other logic is inherited from the base factory.
 */
contract CounterfactualDepositFactoryTron is CounterfactualDepositFactory {
    /**
     * @notice Predicts the Tron CREATE2 address of a counterfactual deposit contract.
     * @dev Uses TronClones with the 0x41 prefix instead of OZ's 0xff to match TVM behavior.
     * @param counterfactualDepositImplementation Implementation contract address.
     * @param paramsHash keccak256 hash of the ABI-encoded route parameters.
     * @param salt Unique salt for address generation.
     * @return Predicted address of the clone on Tron.
     */
    function predictDepositAddress(
        address counterfactualDepositImplementation,
        bytes32 paramsHash,
        bytes32 salt
    ) public view override returns (address) {
        return
            TronClones.predictDeterministicAddressWithImmutableArgs(
                counterfactualDepositImplementation,
                abi.encode(paramsHash),
                salt
            );
    }
}
