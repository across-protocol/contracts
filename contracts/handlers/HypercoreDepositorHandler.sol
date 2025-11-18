// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/SpokePoolMessageHandler.sol";
import "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-v4/security/ReentrancyGuard.sol";
import { CoreWriterLib, PrecompileLib } from "hyper-evm-lib/src/CoreWriterLib.sol";
import { HLConversions } from "hyper-evm-lib/src/common/HLConversions.sol";

/**
 * @title Allows caller to bridge tokens from HyperEVM to Hypercore and send them to an end user's account
 * on Hypercore.
 * @dev This contract should only be deployed on HyperEVM.
 * @dev This contract can replace a MulticallHandler on HyperEVM if the intent only wants to deposit tokens into
 * Hypercore and bypass the other complex arbitrary calldata logic.
 * @dev This contract can also be called directly to deposit tokens into Hypercore on behalf of an end user.
 */
contract HypercoreDepositorHandler is AcrossMessageHandler, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @notice Bridges tokens from HyperEVM to Hypercore and sends them to the end user's account on Hypercore.
     * @dev Requires msg.sender to have approved this contract to spend the tokens.
     * @param token The address of the token to deposit.
     * @param amount The amount of tokens on HyperEVM to deposit.
     * @param user The address of the user on Hypercore to send the tokens to.
     */
    function depositToHypercore(address token, uint256 amount, address user) external nonReentrant {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _bridgeToCore(token, amount);
        _spotSend(user, token, amount);
    }

    /**
     * @notice Entrypoint function if this contract is called by the SpokePool contract following an intent fill.
     * @dev Deposits tokens into Hypercore and sends them to the end user's account on Hypercore.
     * @param token The address of the token sent.
     * @param amount The amount of tokens received by this contract.
     * @param message Encoded end user address.
     */
    function handleV3AcrossMessage(
        address token,
        uint256 amount,
        address /* relayer */,
        bytes memory message
    ) external nonReentrant {
        address user = abi.decode(message, (address));
        _bridgeToCore(token, amount);
        _spotSend(user, token, amount);
    }

    function _bridgeToCore(address token, uint256 evmAmount) internal {
        // Bridge tokens from HyperEVM to Hypercore. This call should revert if this contract has insufficient balance.
        CoreWriterLib.bridgeToCore(token, evmAmount);
    }

    function _spotSend(address user, address token, uint256 evmAmount) internal {
        // Convert EVM amount to wei amount (used in HyperCore)
        uint64 tokenIndex = PrecompileLib.getTokenIndex(token);
        uint64 coreAmount = HLConversions.evmToWei(tokenIndex, evmAmount);

        // use CoreWriterLib to call the spotSend CoreWriter action and send tokens to end user.
        // @dev: the following call does not execute atomically with the deposit into Hypercore.
        // Therefore, this contract will maintain a balance of tokens for one block until the spot send into Hypercore
        // is confirmed.
        CoreWriterLib.spotSend(user, tokenIndex, coreAmount);
    }

    // Native tokens are not supported by this contract.
}
