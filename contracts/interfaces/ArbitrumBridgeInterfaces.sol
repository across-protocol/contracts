// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title Staging ground for incoming and outgoing messages
 * @notice Unlike the standard Eth bridge, native token bridge escrows the custom ERC20 token which is
 * used as native currency on upper layer.
 * @dev Fees are paid in this token. There are certain restrictions on the native token:
 *       - The token can't be rebasing or have a transfer fee
 *       - The token must only be transferrable via a call to the token address itself
 *       - The token must only be able to set allowance via a call to the token address itself
 *       - The token must not have a callback on transfer, and more generally a user must not be able to make a transfer to themselves revert
 *       - The token must have a max of 2^256 - 1 wei total supply unscaled
 *       - The token must have a max of 2^256 - 1 wei total supply when scaled to 18 decimals
 */
interface ArbitrumERC20Bridge {
    /**
     * @notice Returns token that is escrowed in bridge on the lower layer and minted on the upper layer as native currency.
     * @dev This function doesn't exist on the generic Bridge interface.
     * @return address of the native token.
     */
    function nativeToken() external view returns (address);
}

/**
 * @title Inbox for user and contract originated messages
 * @notice Messages created via this inbox are enqueued in the delayed accumulator
 * to await inclusion in the SequencerInbox
 */
interface ArbitrumInboxLike {
    /**
     * @dev we only use this function to check the native token used by the bridge, so we hardcode the interface
     * to return an ArbitrumERC20Bridge instead of a more generic Bridge interface.
     * @return address of the bridge.
     */
    function bridge() external view returns (ArbitrumERC20Bridge);

    /**
     * @notice Put a message in the inbox that can be reexecuted for some fixed amount of time if it reverts
     * @dev Gas limit and maxFeePerGas should not be set to 1 as that is used to trigger the RetryableData error
     * @dev Caller must set msg.value equal to at least `maxSubmissionCost + maxGas * gasPriceBid`.
     *      all msg.value will deposited to callValueRefundAddress on the upper layer
     * @dev More details can be found here: https://developer.arbitrum.io/arbos/l1-to-l2-messaging
     * @param to destination contract address
     * @param callValue call value for retryable message
     * @param maxSubmissionCost Max gas deducted from user's (upper layer) balance to cover base submission fee
     * @param excessFeeRefundAddress gasLimit x maxFeePerGas - execution cost gets credited here on (upper layer) balance
     * @param callValueRefundAddress callvalue gets credited here on upper layer if retryable txn times out or gets cancelled
     * @param gasLimit Max gas deducted from user's upper layer balance to cover upper layer execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param maxFeePerGas price bid for upper layer execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param data ABI encoded data of message
     * @return unique message number of the retryable transaction
     */
    function createRetryableTicket(
        address to,
        uint256 callValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes calldata data
    ) external payable returns (uint256);

    /**
     * @notice Put a message in the inbox that can be reexecuted for some fixed amount of time if it reverts
     * @notice Overloads the `createRetryableTicket` function but is not payable, and should only be called when paying
     * for message using a custom gas token.
     * @dev all tokenTotalFeeAmount will be deposited to callValueRefundAddress on upper layer
     * @dev Gas limit and maxFeePerGas should not be set to 1 as that is used to trigger the RetryableData error
     * @dev In case of native token having non-18 decimals: tokenTotalFeeAmount is denominated in native token's decimals. All other value params - callValue, maxSubmissionCost and maxFeePerGas are denominated in child chain's native 18 decimals.
     * @param to destination contract address
     * @param callValue call value for retryable message
     * @param maxSubmissionCost Max gas deducted from user's upper layer balance to cover base submission fee
     * @param excessFeeRefundAddress the address which receives the difference between execution fee paid and the actual execution cost. In case this address is a contract, funds will be received in its alias on upper layer.
     * @param callValueRefundAddress callvalue gets credited here on upper layer if retryable txn times out or gets cancelled. In case this address is a contract, funds will be received in its alias on upper layer.
     * @param gasLimit Max gas deducted from user's balance to cover execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param maxFeePerGas price bid for execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param tokenTotalFeeAmount amount of fees to be deposited in native token to cover for retryable ticket cost
     * @param data ABI encoded data of message
     * @return unique message number of the retryable transaction
     */
    function createRetryableTicket(
        address to,
        uint256 callValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        uint256 tokenTotalFeeAmount,
        bytes calldata data
    ) external returns (uint256);

    /**
     * @notice Put a message in the source chain inbox that can be reexecuted for some fixed amount of time if it reverts
     * @dev Same as createRetryableTicket, but does not guarantee that submission will succeed by requiring the needed
     * funds come from the deposit alone, rather than falling back on the user's balance
     * @dev Advanced usage only (does not rewrite aliases for excessFeeRefundAddress and callValueRefundAddress).
     * createRetryableTicket method is the recommended standard.
     * @dev Gas limit and maxFeePerGas should not be set to 1 as that is used to trigger the RetryableData error
     * @param to destination contract address
     * @param callValue call value for retryable message
     * @param maxSubmissionCost Max gas deducted from user's source chain balance to cover base submission fee
     * @param excessFeeRefundAddress gasLimit x maxFeePerGas - execution cost gets credited here on source chain balance
     * @param callValueRefundAddress callvalue gets credited here on source chain if retryable txn times out or gets cancelled
     * @param gasLimit Max gas deducted from user's balance to cover execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param maxFeePerGas price bid for execution. Should not be set to 1 (magic value used to trigger the RetryableData error)
     * @param data ABI encoded data of the message
     * @return unique message number of the retryable transaction
     */
    function unsafeCreateRetryableTicket(
        address to,
        uint256 callValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes calldata data
    ) external payable returns (uint256);
}

/**
 * @notice Generic gateway contract for bridging standard ERC20s to Arbitrum-like networks.
 */
interface ArbitrumERC20GatewayLike {
    /**
     * @notice Deposit ERC20 token from Ethereum into Arbitrum-like networks.
     * @dev Upper layer address alias will not be applied to the following types of addresses on lower layer:
     *      - an externally-owned account
     *      - a contract in construction
     *      - an address where a contract will be created
     *      - an address where a contract lived, but was destroyed
     * @param _sourceToken address of ERC20 on source chain.
     * @param _refundTo Account, or its alias if it has code on the source chain, to be credited with excess gas refund at destination
     * @param _to Account to be credited with the tokens in the L3 (can be the user's L3 account or a contract),
     * not subject to aliasing. This account, or its alias if it has code on the source chain, will also be able to
     * cancel the retryable ticket and receive callvalue refund
     * @param _amount Token Amount
     * @param _maxGas Max gas deducted from user's balance to cover execution
     * @param _gasPriceBid Gas price for execution
     * @param _data encoded data from router and user
     * @return res abi encoded inbox sequence number
     */
    function outboundTransferCustomRefund(
        address _sourceToken,
        address _refundTo,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory);

    /**
     * @notice Deprecated in favor of outboundTransferCustomRefund but still used in custom bridges
     * like the DAI bridge.
     * @dev Refunded to aliased address of sender if sender has code on source chain, otherwise to to sender's EOA on destination chain.
     * @param _sourceToken address of ERC20
     * @param _to Account to be credited with the tokens at the destination (can be the user's account or a contract),
     * not subject to aliasing. This account, or its alias if it has code in the source chain, will also be able to
     * cancel the retryable ticket and receive callvalue refund
     * @param _amount Token Amount
     * @param _maxGas Max gas deducted from user's balance to cover execution
     * @param _gasPriceBid Gas price for execution
     * @param _data encoded data from router and user
     * @return res abi encoded inbox sequence number
     */
    function outboundTransfer(
        address _sourceToken,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory);

    /**
     * @notice get ERC20 gateway for token.
     * @param _token ERC20 address.
     * @return address of ERC20 gateway.
     */
    function getGateway(address _token) external view returns (address);
}
