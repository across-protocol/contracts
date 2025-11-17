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

    // Emitted when leftover tokens following a Hypercore deposit are sent to the end user.
    event DrainedTokens(address indexed destination, address indexed token, uint256 amount);

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
     * @notice Main entrypoint for the handler called by the SpokePool contract.
     * @dev This will execute all calls encoded in the msg. The caller is responsible for making sure all tokens are
     * drained from this contract by the end of the series of calls. If not, they can be stolen.
     * A drainLeftoverTokens call can be included as a way to drain any remaining tokens from this contract.
     * @param message abi encoded array of Call structs, containing a target, callData, and value for each call that
     * the contract should make.
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
        CoreWriterLib.spotSend(user, tokenIndex, coreAmount);

        // If there are leftover tokens, send them to the recipient on Hyperevm.
        _drainRemainingTokens(token, user);
    }

    function _drainRemainingTokens(address token, address destination) internal {
        // For now, native tokens are not supported by this contract so we don't need to handle any.
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            IERC20(token).safeTransfer(destination, amount);
            emit DrainedTokens(destination, token, amount);
        }
    }

    function _requireTxOriginIsHypercoreDepositor() internal view {
        // We check tx.origin to allow the whitelisted account to call this contract via another proxy contract.
        // @todo: Is this a safe check to add permissioning properties that we want?
        if (!hasRole(HYPERCORE_DEPOSITOR_ROLE, tx.origin)) revert NotRelayer();
    }

    // Native tokens are not supported by this contract.
}
