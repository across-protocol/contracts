// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Interface of Linea's Canonical Message Service
 * See https://github.com/Consensys/linea-contracts/blob/3cf85529fd4539eb06ba998030c37e47f98c528a/contracts/interfaces/IMessageService.sol
 */
interface IMessageService {
    /**
     * @notice Sends a message for transporting from the given chain.
     * @dev This function should be called with a msg.value = _value + _fee. The fee will be paid on the destination chain.
     * @param _to The destination address on the destination chain.
     * @param _fee The message service fee on the origin chain.
     * @param _calldata The calldata used by the destination message service to call the destination contract.
     */
    function sendMessage(
        address _to,
        uint256 _fee,
        bytes calldata _calldata
    ) external payable;

    /**
     * @notice Returns the original sender of the message on the origin layer.
     */
    function sender() external view returns (address);

    /**
     * @notice Minimum fee to use when sending a message. Currently, only exists on L2MessageService.
     * See https://github.com/Consensys/linea-contracts/blob/3cf85529fd4539eb06ba998030c37e47f98c528a/contracts/messageService/l2/L2MessageService.sol#L37
     */
    function minimumFeeInWei() external view returns (uint256);
}

/**
 * @notice Interface of Linea's Canonical Token Bridge
 * See https://github.com/Consensys/linea-contracts/blob/3cf85529fd4539eb06ba998030c37e47f98c528a/contracts/tokenBridge/interfaces/ITokenBridge.sol
 */
interface ITokenBridge {
    /**
     * @notice This function is the single entry point to bridge tokens to the
     *   other chain, both for native and already bridged tokens. You can use it
     *   to bridge any ERC20. If the token is bridged for the first time an ERC20
     *   (BridgedToken.sol) will be automatically deployed on the target chain.
     * @dev User should first allow the bridge to transfer tokens on his behalf.
     *   Alternatively, you can use `bridgeTokenWithPermit` to do so in a single
     *   transaction. If you want the transfer to be automatically executed on the
     *   destination chain. You should send enough ETH to pay the postman fees.
     *   Note that Linea can reserve some tokens (which use a dedicated bridge).
     *   In this case, the token cannot be bridged. Linea can only reserve tokens
     *   that have not been bridged yet.
     *   Linea can pause the bridge for security reason. In this case new bridge
     *   transaction would revert.
     * @param _token The address of the token to be bridged.
     * @param _amount The amount of the token to be bridged.
     * @param _recipient The address that will receive the tokens on the other chain.
     */
    function bridgeToken(
        address _token,
        uint256 _amount,
        address _recipient
    ) external payable;
}

interface IUSDCBridge {
    function usdc() external view returns (address);

    /**
     * @dev Sends the sender's USDC from L1 to the recipient on L2, locks the USDC sent
     * in this contract and sends a message to the message bridge
     * contract to mint the equivalent USDC on L2
     * @param amount The amount of USDC to send
     * @param to The recipient's address to receive the funds
     */
    function depositTo(uint256 amount, address to) external payable;
}
