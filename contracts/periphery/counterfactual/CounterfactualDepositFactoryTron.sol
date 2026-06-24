// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { TronClones } from "../../libraries/TronClones.sol";
import { CounterfactualDepositFactory } from "./CounterfactualDepositFactory.sol";

/**
 * @title CounterfactualDepositFactoryTron
 * @notice Tron-compatible variant of `CounterfactualDepositFactory` for deploying counterfactual
 *         proxies via CREATE2 on the TVM.
 * @dev Tron's TVM uses 0x41 instead of EVM's 0xff as the CREATE2 address derivation prefix. The
 *      `create2` opcode itself uses 0x41 natively, so deployment via the inherited `deploy(...)`
 *      (which uses `new BeaconProxy{ salt: 0 }(...)`) produces the correct address on Tron. Only
 *      OZ's `Create2.computeAddress` — used for off-chain-style prediction — hardcodes 0xff and would
 *      return the wrong address. This variant overrides the `_computeProxyAddress` hook to predict
 *      with the 0x41 prefix; all other logic is inherited unchanged.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositFactoryTron is CounterfactualDepositFactory {
    constructor(address beacon) CounterfactualDepositFactory(beacon) {} // solhint-disable-line no-empty-blocks

    /// @dev TRON OVERRIDE: predict the `BeaconProxy` CREATE2 address using the 0x41 prefix.
    function _computeProxyAddress(bytes32 salt, bytes32 initCodeHash) internal view override returns (address) {
        return TronClones.computeAddress(salt, initCodeHash, address(this));
    }
}
