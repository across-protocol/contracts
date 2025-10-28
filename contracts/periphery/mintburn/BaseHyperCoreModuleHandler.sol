//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { AuthorizedFundedFlow } from "./AuthorizedFundedFlow.sol";
import { HyperCoreFlowExecutor } from "./HyperCoreFlowExecutor.sol";

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @dev IMPORTANT. The storage layout of this contract is meant to be in sync with `HyperCoreFlowExeutor` in terms of
    handling `AccessControl` storage slots specifically. The roles set on the handler (inheritor of this contract) are
    meant to be enforceable in the delegatecalls made to `HyperCoreFlowExecutor`
 */
abstract contract BaseHyperCoreModuleHandler is AccessControl, AuthorizedFundedFlow {
    /// @notice Address of the underlying hypercore module
    address public immutable hyperCoreModule;

    constructor(address _donationBox, address _baseToken, bytes32 _roleAdmin) {
        hyperCoreModule = address(new HyperCoreFlowExecutor(_donationBox, _baseToken));

        // TODO: why doesn't work?
        // _setRoleAdmin(HyperCoreFlowExecutor.PERMISSIONED_BOT_ROLE, _roleAdmin);
        // _setRoleAdmin(HyperCoreFlowExecutor.FUNDS_SWEEPER_ROLE, _roleAdmin);
    }

    /// @notice External delegatecall entrypoint to the HyperCore module
    /// @dev Permissioning is enforced by the delegated function's own modifiers (e.g. onlyPermissionedBot)
    function callHyperCoreModule(bytes calldata data) external payable returns (bytes memory) {
        return _delegateToHyperCore(data);
    }

    /// @notice Internal delegatecall helper
    function _delegateToHyperCore(bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory ret) = hyperCoreModule.delegatecall(data);
        if (!success) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}
