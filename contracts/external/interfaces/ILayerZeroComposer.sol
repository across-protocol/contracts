// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

/**
 * @title ILayerZeroComposer
 * @dev Copied over from https://github.com/LayerZero-Labs/LayerZero-v2/blob/2ff4988f85b5c94032eb71bbc4073e69c078179d/packages/layerzero-v2/evm/protocol/contracts/interfaces/ILayerZeroComposer.sol#L8
 */
interface ILayerZeroComposer {
    /**
     * @notice Composes a LayerZero message from an OApp.
     * @param _from The address initiating the composition, typically the OApp where the lzReceive was called.
     * @param _guid The unique identifier for the corresponding LayerZero src/dst tx.
     * @param _message The composed message payload in bytes. NOT necessarily the same payload passed via lzReceive.
     * @param _executor The address of the executor for the composed message.
     * @param _extraData Additional arbitrary data in bytes passed by the entity who executes the lzCompose.
     */
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}
