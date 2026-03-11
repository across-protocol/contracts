// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { StdConstants } from "forge-std/StdConstants.sol";

/// @dev Shared utilities for deploying contracts via the deterministic deployment proxy (CREATE2).
/// Address: 0x4e59b44847b379578588920cA78FbF26c0B4956C (Arachnid's factory, available on all chains).
///
/// The proxy takes raw calldata: `salt ++ initCode`, where initCode = creationCode + abi.encode(args).
/// Deployed address = keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:]
abstract contract Create2DeployUtils is Script {
    /// @dev Deploys a contract via CREATE2 if not already deployed. Returns the deployed address.
    function _deployCreate2(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        deployed = _predictCreate2(salt, initCode);

        if (deployed.code.length > 0) {
            console.log("  Already deployed at:", deployed);
            return deployed;
        }

        (bool success, ) = StdConstants.CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(success, "CREATE2 deployment failed");
        require(deployed.code.length > 0, "CREATE2 deployment did not produce code");
    }

    /// @dev Predicts the CREATE2 address for a given salt and initCode.
    function _predictCreate2(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xff), StdConstants.CREATE2_FACTORY, salt, keccak256(initCode))
                        )
                    )
                )
            );
    }
}
