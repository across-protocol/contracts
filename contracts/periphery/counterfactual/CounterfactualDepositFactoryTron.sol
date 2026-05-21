// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { TronClones } from "../../libraries/TronClones.sol";
import { CounterfactualDepositFactory } from "./CounterfactualDepositFactory.sol";
import { CloneArgs, CounterfactualCloneArgs } from "./CounterfactualCloneArgs.sol";

/**
 * @title CounterfactualDepositFactoryTron
 * @notice Tron-compatible factory for deploying counterfactual deposit clones via CREATE2.
 * @dev Tron's TVM uses 0x41 instead of 0xff as the CREATE2 address derivation prefix. OZ Clones
 *      deploys correctly (the create2 opcode natively uses 0x41 on Tron), but its address prediction
 *      hardcodes 0xff. This factory overrides `predictDepositAddress` to use `TronClones` with the
 *      correct 0x41 prefix. All other logic is inherited from the base factory.
 */
contract CounterfactualDepositFactoryTron is CounterfactualDepositFactory {
    using CounterfactualCloneArgs for CloneArgs;

    /// @inheritdoc CounterfactualDepositFactory
    function predictDepositAddress(
        address dispatcher,
        CloneArgs calldata cloneArgs,
        bytes32 salt
    ) public view override returns (address) {
        return TronClones.predictDeterministicAddressWithImmutableArgs(dispatcher, abi.encode(cloneArgs.hash()), salt);
    }
}
