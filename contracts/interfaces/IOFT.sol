// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice This file contains minimal copies of relevant structs / interfaces for OFT bridging. Source code link:
 * https://github.com/LayerZero-Labs/LayerZero-v2/blob/9a4049ae3a374e1c0ef01ac9fb53dd83f4257a68/packages/layerzero-v2/evm/oapp/contracts/oft/interfaces/IOFT.sol
 * It's also published as a part of an npm package: @layerzerolabs/oft-evm. The published code is incompatible with
 * our compiler version requirements, so we copy it here instead
 */

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

/**
 * @dev Struct representing token parameters for the OFT send() operation.
 */
struct SendParam {
    uint32 dstEid; // Destination endpoint ID.
    bytes32 to; // Recipient address.
    uint256 amountLD; // Amount to send in local decimals.
    uint256 minAmountLD; // Minimum amount to send in local decimals.
    bytes extraOptions; // Additional options supplied by the caller to be used in the LayerZero message.
    bytes composeMsg; // The composed message for the send() operation.
    bytes oftCmd; // The OFT command to be executed, unused in default OFT implementations.
}

/**
 * @dev Struct representing OFT receipt information.
 */
struct OFTReceipt {
    uint256 amountSentLD; // Amount of tokens ACTUALLY debited from the sender in local decimals.
    // @dev In non-default implementations, the amountReceivedLD COULD differ from this value.
    uint256 amountReceivedLD; // Amount of tokens to be received on the remote side.
}

/**
 * @title IOFT
 * @dev Interface for the OftChain (OFT) token.
 * @dev Does not inherit ERC20 to accommodate usage by OFTAdapter as well.
 * @dev This specific interface ID is '0x02e49c2c'.
 */
interface IOFT {
    /**
     * @notice Retrieves the address of the token associated with the OFT.
     * @return token The address of the ERC20 token implementation.
     */
    function token() external view returns (address);

    /**
     * @notice Provides a quote for the send() operation.
     * @param _sendParam The parameters for the send() operation.
     * @param _payInLzToken Flag indicating whether the caller is paying in the LZ token.
     * @return fee The calculated LayerZero messaging fee from the send() operation.
     *
     * @dev MessagingFee: LayerZero msg fee
     *  - nativeFee: The native fee.
     *  - lzTokenFee: The lzToken fee.
     */
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken) external view returns (MessagingFee memory);

    /**
     * @notice Executes the send() operation.
     * @param _sendParam The parameters for the send operation.
     * @param _fee The fee information supplied by the caller.
     *      - nativeFee: The native fee.
     *      - lzTokenFee: The lzToken fee.
     * @param _refundAddress The address to receive any excess funds from fees etc. on the src.
     * @return receipt The LayerZero messaging receipt from the send() operation.
     * @return oftReceipt The OFT receipt information.
     *
     * @dev MessagingReceipt: LayerZero msg receipt
     *  - guid: The unique identifier for the sent message.
     *  - nonce: The nonce of the sent message.
     *  - fee: The LayerZero fee incurred for the message.
     */
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory, OFTReceipt memory);
}
