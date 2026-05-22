// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { TronClones } from "../../libraries/TronClones.sol";
import { CounterfactualDepositFactory } from "./CounterfactualDepositFactory.sol";

/**
 * @title CounterfactualDepositFactoryTron
 * @notice Tron-compatible factory for deploying counterfactual deposit clones via CREATE2.
 * @dev Tron's TVM uses 0x41 instead of 0xff as the CREATE2 address derivation prefix.
 *      OZ Clones deploys correctly (the CREATE2 opcode natively uses 0x41 on Tron), but its
 *      address prediction hardcodes 0xff. This factory overrides `predictDepositAddress` to use
 *      `TronClones` with the correct 0x41 prefix. All other logic is inherited from the base factory.
 *
 *      Tron clones live at different addresses than EVM clones for the same identity — Tron requires
 *      its own dispatcher (different transfer hook), so the dispatcher address passed at construction
 *      differs from the mainline EVM dispatcher.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositFactoryTron is CounterfactualDepositFactory {
    constructor(address _dispatcher) CounterfactualDepositFactory(_dispatcher) {} // solhint-disable-line no-empty-blocks

    /// @inheritdoc CounterfactualDepositFactory
    function predictDepositAddress(bytes32 identityHash, bytes32 initialRoot) public view override returns (address) {
        bytes32 salt = keccak256(abi.encode(identityHash, initialRoot));
        return TronClones.predictDeterministicAddressWithImmutableArgs(dispatcher, abi.encode(identityHash), salt);
    }
}
