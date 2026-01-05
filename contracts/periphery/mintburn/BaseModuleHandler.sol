//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { AuthorizedFundedFlow } from "./AuthorizedFundedFlow.sol";
import { HyperCoreFlowExecutor } from "./HyperCoreFlowExecutor.sol";
import { HyperCoreFlowRoles } from "./HyperCoreFlowRoles.sol";

// Note: v5 is necessary since v4 does not use ERC-7201.
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts-v4/security/ReentrancyGuard.sol";

/**
 * @notice Base contract for module handlers that use delegatecall to interact with HyperCoreFlowExecutor
 * @dev Uses AccessControlUpgradeable to ensure storage compatibility with HyperCoreFlowExecutor when using delegatecall
 */
abstract contract BaseModuleHandler is
    AccessControlUpgradeable,
    ReentrancyGuard,
    AuthorizedFundedFlow,
    HyperCoreFlowRoles
{
    /// @notice Address of the underlying hypercore module
    address public immutable hyperCoreModule;

    constructor(address _donationBox, address _baseToken, bytes32 _roleAdmin) {
        hyperCoreModule = address(new HyperCoreFlowExecutor(_donationBox, _baseToken));

        _setRoleAdmin(PERMISSIONED_BOT_ROLE, _roleAdmin);
        _setRoleAdmin(FUNDS_SWEEPER_ROLE, _roleAdmin);
    }

    /// @notice Fallback function to proxy all calls to the HyperCore module via delegatecall
    /// @dev Permissioning is enforced by the delegated function's own modifiers (e.g. onlyPermissionedBot)
    fallback(bytes calldata data) external nonReentrant returns (bytes memory) {
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
