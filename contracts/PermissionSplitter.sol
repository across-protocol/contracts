// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

// TODO: Make upgradeable.
contract PermissionSplitter is AccessControl, MultiCaller {
    // Inherited admin role from AccessControl. Should be assigned to Across DAO multisig
    // bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    // Maps function signatures to role identifiers, which gatekeeps access to these functions to
    // only role holders.
    // Assumptions: Each function signature is unique, therefore the function signature itself can be used
    // as the AccessControl.Role identifier. This seems like a weak assumption?
    mapping(bytes4 => bytes32) public roleForFunctionSig;

    // TODO: Implement this as a fallback.
    // Can execute pending proposal after liveness period has elapsed.
    function executeAction(
        address target,
        bytes4 functionSig,
        bytes memory callData,
        uint256 msgValue
    ) external {
        if (roleForFunctionSig[functionSig] == bytes32(0)) {
            // pass through, no role required
        } else {
            require(hasRole(roleForFunctionSig[bytes32(functionSig)], msg.sender), "invalid role for function sig.");

            // execute functionSig with callData on target, optionally passing msgValue
        }
    }
}
