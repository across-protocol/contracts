// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * Imported from https://github.com/defi-wonderland/opUSDC
 * https://github.com/defi-wonderland/opUSDC/blob/ef22e5731f1655bf5249b2160452cce9aa06ff3f/src/interfaces/IOpUSDCBridgeAdapter.sol#L198C1-L204C84
 */
interface IOpUSDCBridgeAdapter {
    /**
     * @notice Send tokens to another chain through the linked adapter
     * @param _to The target address on the destination chain
     * @param _amount The amount of tokens to send
     * @param _minGasLimit Minimum gas limit that the message can be executed with
     */
    function sendMessage(
        address _to,
        uint256 _amount,
        uint32 _minGasLimit
    ) external;
}
