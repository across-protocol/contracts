// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts-v4/utils/Address.sol";
import { Bytes32ToAddress } from "./libraries/AddressConverters.sol";
import { AcrossMessageHandler } from "./interfaces/SpokePoolMessageHandler.sol";

/**
 * @title TransferProxy
 * @notice Implements the SpokePool deposit interface but simply transfers tokens to the recipient on the origin chain.
 * Users pass this contract's address as `spokePool` in the existing `swapAndBridge*` periphery methods to perform
 * swap-only (no bridge) operations. All gasless flows (permit, permit2, EIP-3009) work automatically with zero
 * periphery changes.
 * @dev Stateless and permissionless — no constructor arguments, deployable via CREATE2 for deterministic addresses.
 * Safety: requires destinationChainId == block.chainid to prevent accidental cross-chain misuse.
 * If message is non-empty and recipient is a contract, calls handleV3AcrossMessage on the recipient,
 * mirroring SpokePool behavior to enable MulticallHandler composition and metadata emission.
 */
contract TransferProxy {
    using SafeERC20 for IERC20;
    using Bytes32ToAddress for bytes32;
    using Address for address;

    error InvalidDestinationChainId();
    error InvalidOutputToken();
    error InvalidOutputAmount();

    event Transfer(address indexed inputToken, address indexed recipient, uint256 inputAmount);

    function deposit(
        bytes32, // depositor
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32, // exclusiveRelayer
        uint32, // quoteTimestamp
        uint32, // fillDeadline
        uint32, // exclusivityDeadline
        bytes calldata message
    ) external {
        _transfer(inputToken, outputToken, recipient, inputAmount, outputAmount, destinationChainId, message);
    }

    function unsafeDeposit(
        bytes32, // depositor
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32, // exclusiveRelayer
        uint256, // depositNonce
        uint32, // quoteTimestamp
        uint32, // fillDeadline
        uint32, // exclusivityParameter
        bytes calldata message
    ) external {
        _transfer(inputToken, outputToken, recipient, inputAmount, outputAmount, destinationChainId, message);
    }

    function _transfer(
        bytes32 inputToken,
        bytes32 outputToken,
        bytes32 recipient,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes calldata message
    ) private {
        if (destinationChainId != block.chainid) revert InvalidDestinationChainId();
        if (inputToken != outputToken) revert InvalidOutputToken();
        if (inputAmount != outputAmount) revert InvalidOutputAmount();
        address token = inputToken.toAddress();
        address to = recipient.toAddress();
        IERC20(token).safeTransferFrom(msg.sender, to, inputAmount);
        emit Transfer(token, to, inputAmount);

        if (message.length > 0 && to.isContract()) {
            AcrossMessageHandler(to).handleV3AcrossMessage(token, inputAmount, msg.sender, message);
        }
    }
}
