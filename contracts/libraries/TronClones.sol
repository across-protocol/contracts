// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title TronClones
 * @notice Tron-compatible CREATE2 address prediction for EIP-1167 clones with immutable args.
 * @dev Tron's TVM uses 0x41 instead of EVM's 0xff as the CREATE2 address derivation prefix:
 *      TVM:  keccak256(0x41 ++ deployer ++ salt ++ keccak256(initcode))[12:]
 *      EVM:  keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))[12:]
 *
 *      The create2 opcode on Tron natively uses 0x41, so deployment via OZ Clones works correctly.
 *      However, OZ's Create2.computeAddress hardcodes 0xff for off-chain-style prediction, producing
 *      wrong addresses on Tron. This library provides a prediction function that uses 0x41 to match.
 */
library TronClones {
    /**
     * @notice Predicts the Tron CREATE2 address of a clone with immutable args, deployed from this contract.
     * @param implementation The implementation contract the clone delegates to.
     * @param args The immutable args appended to the clone bytecode.
     * @param salt The CREATE2 salt for deterministic address generation.
     * @return The predicted clone address on Tron.
     */
    function predictDeterministicAddressWithImmutableArgs(
        address implementation,
        bytes memory args,
        bytes32 salt
    ) internal view returns (address) {
        return predictDeterministicAddressWithImmutableArgs(implementation, args, salt, address(this));
    }

    /**
     * @notice Predicts the Tron CREATE2 address of a clone with immutable args, deployed from `deployer`.
     * @param implementation The implementation contract the clone delegates to.
     * @param args The immutable args appended to the clone bytecode.
     * @param salt The CREATE2 salt for deterministic address generation.
     * @param deployer The address of the contract that will deploy the clone.
     * @return predicted The predicted clone address on Tron.
     */
    function predictDeterministicAddressWithImmutableArgs(
        address implementation,
        bytes memory args,
        bytes32 salt,
        address deployer
    ) internal pure returns (address predicted) {
        bytes32 bytecodeHash = keccak256(_cloneCodeWithImmutableArgs(implementation, args));
        return _computeTronAddress(salt, bytecodeHash, deployer);
    }

    /**
     * @dev Tron CREATE2 address computation using 0x41 prefix.
     *      Memory layout mirrors OZ Create2.computeAddress but replaces 0xff with 0x41.
     * @param salt The CREATE2 salt.
     * @param bytecodeHash The keccak256 hash of the clone's init code.
     * @param deployer The deploying contract address.
     * @return addr The predicted address.
     */
    function _computeTronAddress(
        bytes32 salt,
        bytes32 bytecodeHash,
        address deployer
    ) private pure returns (address addr) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), bytecodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer)
            let start := add(ptr, 0x0b)
            mstore8(start, 0x41) // Tron prefix (EVM uses 0xff)
            addr := and(keccak256(start, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /**
     * @dev Generates EIP-1167 minimal proxy bytecode with immutable args appended.
     *      Identical to OZ Clones._cloneCodeWithImmutableArgs (replicated because it is private).
     * @param implementation The implementation contract address embedded in the proxy bytecode.
     * @param args The immutable args appended after the proxy bytecode.
     * @return The complete clone init code.
     */
    function _cloneCodeWithImmutableArgs(
        address implementation,
        bytes memory args
    ) private pure returns (bytes memory) {
        return
            abi.encodePacked(
                hex"61",
                uint16(args.length + 0x2d),
                hex"3d81600a3d39f3363d3d373d3d3d363d73",
                implementation,
                hex"5af43d82803e903d91602b57fd5bf3",
                args
            );
    }
}
