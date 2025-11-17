// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/SpokePoolMessageHandler.sol";
import "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-v4/access/AccessControl.sol";
import "@openzeppelin/contracts-v4/security/ReentrancyGuard.sol";
import { CoreWriterLib, PrecompileLib } from "@hyper-evm-lib/src/CoreWriterLib.sol";
import { HLConversions } from "@hyper-evm-lib/src/common/HLConversions.sol";

/**
 * @title Bespoke version of the MulticallHandler contract that allows whitelisted relayers to deposit Across Deposit
 * output tokens into Hypercore (from HyperEVM) on behalf of the end user.
 * @dev This contract is permissioned to only be callable by those with the DEPOSITOR.
 * @dev This contract should only be deployed on HyperEVM.
 */
contract HypercoreDepositorHandler is AcrossMessageHandler, ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // Role identifier for tx.origins that can ultimately call this contract.
    bytes32 public constant HYPERCORE_DEPOSITOR_ROLE = keccak256("DEPOSITOR");

    // Errors
    error NotRelayer();

    /**
     * @notice Constructor that grants the DEFAULT_ADMIN_ROLE and the DEPOSITOR roles.
     * @param admin Address that will have DEFAULT_ADMIN_ROLE
     * @param initialDepositors List of initial depositors to grant the DEPOSITOR role to.
     */
    constructor(address admin, address[] memory initialDepositors) {
        _grantRole(HYPERCORE_DEPOSITOR_ROLE, msg.sender);
        for (uint256 i = 0; i < initialDepositors.length; i++) {
            _grantRole(HYPERCORE_DEPOSITOR_ROLE, initialDepositors[i]);
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    modifier onlyWhitelistedOrigin() {
        _requireTxOriginIsHypercoreDepositor();
        _;
    }

    /**
     * @notice Main entrypoint for the handler called by the SpokePool contract. Sends tokens to the
     * end user on Hypercore using funds received on this contract on HyperEVM.
     * @dev The tx.origin of this transaction must be an account with the DEPOSITOR role.
     */
    function handleV3AcrossMessage(
        address token,
        uint256 evmAmount,
        address,
        bytes memory message
    ) external nonReentrant onlyWhitelistedOrigin {
        address user = abi.decode(message, (address));

        CoreWriterLib.bridgeToCore(token, evmAmount);

        // Convert EVM amount to wei amount (used in HyperCore)
        uint64 tokenIndex = PrecompileLib.getTokenIndex(token);
        uint64 coreAmount = HLConversions.evmToWei(tokenIndex, evmAmount);

        // use CoreWriterLib to call the spotSend CoreWriter action and send tokens to end user.
        // @dev: the following call does not execute atomically with the deposit into Hypercore.
        // Therefore, this contract will maintain a balance of tokens for one block until the spot send into Hypercore
        // is confirmed.
        CoreWriterLib.spotSend(user, tokenIndex, coreAmount);
    }

    function _requireTxOriginIsHypercoreDepositor() internal view {
        // We check tx.origin to allow the whitelisted account to call this contract via another proxy contract.
        // @todo: Is this a safe check to add permissioning properties that we want?
        if (!hasRole(HYPERCORE_DEPOSITOR_ROLE, tx.origin)) revert NotRelayer();
    }

    // Native tokens are not supported by this contract.
}
