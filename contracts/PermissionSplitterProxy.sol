// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract PermissionSplitterProxy is AccessControl, MultiCaller {
    // Inherited admin role from AccessControl. Should be assigned to Across DAO Safe.
    // bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    // Maps function signatures to role identifiers, which gatekeeps access to these functions to
    // only role holders.
    mapping(bytes4 => bytes32) public roleForSelector;

    address public target;

    event TargetUpdated(address indexed newTarget);
    event RoleForSelectorSet(bytes4 indexed selector, bytes32 indexed role);

    constructor(address _target) {
        _init(_target);
    }

    // Public function!
    // Note: these have two underscores in front to prevent any collisions with the target contract.
    function __setTarget(address _target) public onlyRole(DEFAULT_ADMIN_ROLE) {
        target = _target;
        emit TargetUpdated(_target);
    }

    // Public function!
    // Note: these have two underscores in front to prevent any collisions with the target contract.
    function __setRoleForSelector(bytes4 selector, bytes32 role) public onlyRole(DEFAULT_ADMIN_ROLE) {
        roleForSelector[selector] = role;
        emit RoleForSelectorSet(selector, role);
    }

    function _init(address _target) internal virtual {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        __setTarget(_target);
    }

    function _isAllowedToCall(address caller, bytes calldata callData) internal view virtual returns (bool) {
        bytes4 selector;
        if (callData.length < 4) {
            // This handles any empty callData, which is a call to the fallback function.
            selector = bytes4(0);
        } else {
            selector = bytes4(callData[:4]);
        }
        return hasRole(DEFAULT_ADMIN_ROLE, caller) || hasRole(roleForSelector[selector], caller);
    }

    /**
     * @dev Forwards the current call to `implementation`.
     *
     * This function does not return to its internal call site, it will return directly to the external caller.
     * Note: this function is a modified _delegate function here:
     // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/002a7c8812e73c282b91e14541ce9b93a6de1172/contracts/proxy/Proxy.sol#L22-L45
     */
    function _forward(address _target) internal {
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := call(gas(), _target, callvalue(), 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // call returns 0 on error.
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    // Executes an action on the target.
    function _executeAction() internal virtual {
        require(_isAllowedToCall(msg.sender, msg.data), "Not allowed to call");
        _forward(target);
    }

    /**
     * @dev Fallback function that forwards calls to the target. Will run if no other
     * function in the contract matches the call data.
     */
    fallback() external payable virtual {
        _executeAction();
    }

    /**
     * @dev Fallback function that delegates calls to the target. Will run if call data
     * is empty.
     */
    receive() external payable virtual {
        _executeAction();
    }
}
