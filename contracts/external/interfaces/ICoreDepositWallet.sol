/*
 * Copyright 2025 Circle Internet Group, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
pragma solidity ^0.8.0;

/**
 * @title IForwardDepositReceiver
 * @notice Interface for a contract that can receive deposits from the CCTP Forwarder
 */
interface IForwardDepositReceiver {
    /**
     * @notice Deposit tokens for a recipient
     * @param recipient Recipient of the deposit
     * @param amount Amount of tokens to deposit
     * @param destinationId Forwarding-address-specific id used in conjunction with
     * recipient to route the deposit to a specific location.
     */
    function depositFor(address recipient, uint256 amount, uint32 destinationId) external;
}

/**
 * @title ICoreDepositWallet
 * @notice Interface for the core deposit wallet
 */
interface ICoreDepositWallet is IForwardDepositReceiver {
    /**
     * @notice Deposits tokens for the sender.
     * @param amount The amount of tokens being deposited.
     * @param destinationDex The destination dex on HyperCore.
     */
    function deposit(uint256 amount, uint32 destinationDex) external;

    /**
     * @notice Handles the token transfer from the ICoreDepositWallet to the recipient.
     * @param to The address receiving the tokens.
     * @param amount The amount of tokens being transferred.
     * @return success True if the transfer succeeded.
     */
    function transfer(address to, uint256 amount) external returns (bool success);

    /**
     * @notice Handles cross-chain token withdrawals from HyperCore to a destination chain via CCTP.
     * @dev This function initiates a cross-chain transfer of tokens using CCTP to mint tokens on the destination chain.
     *      It constructs and sends a CCTP message containing encoded hook data that embeds the optional user-provided
     *      data to be used on the destination chain and determines the CCTP forwarding behavior.
     *
     * @dev Requirements:
     *      - Caller must be the token system address.
     *      - `amount` must be strictly greater than the computed maximum withdrawal fee
     *        (see calculateCrossChainWithdrawalFee).
     *
     * @dev CCTP behavior:
     *      - The CCTP message's destinationCaller is always set to `bytes32(0)` and anyone can call
     *        MessageTransmitterV2.receiveMessage directly on the destination chain.
     *
     * @dev Forwarding is the process of completing the mint on the destination chain by paying gas to
     *      submit a transaction that includes the CCTP attestation. When forwarding is requested:
     *      - The forwarder subtracts a configured amount of minted tokens from the final recipient,
     *        not exceeding the CCTP maxFee.
     *      - This forwarding amount is added to the CCTP maxFee to compute the total fee for the
     *        cross-chain withdrawal.
     *
     * @dev Forwarding logic:
     * The forwarding logic is determined by the user-provided data:
     *      - If `data` is empty: the hook data will be a default forwarding hook and forwarding will be performed.
     *      - If `data` begins with the CCTP forwarding magic bytes: the hook data will embed `data` and forwarding will be performed.
     *      - Otherwise: the hook data will embed `data` and forwarding will NOT be performed.
     *
     * @dev Hook data encoding:
     * The hook data is constructed using the `CrossChainWithdrawalHookData` library. See that library for the full
     * encoding details.
     *
     * @param from The HyperCore address debited by the cross-chain withdrawal.
     * @param destinationRecipient The address receiving the minted tokens on the destination chain, as bytes32.
     * @param destinationChainId The CCTP domain ID of the destination chain.
     * @param amount The amount of tokens being transferred.
     * @param coreNonce The HyperCore transaction nonce.
     * @param data Optional user-provided data to embed in the CCTP message payload hook data; also determines the
     *             forwarding logic as described above. Must be less than or equal to MAX_HOOK_DATA_SIZE.
     */
    function coreReceiveWithData(
        address from,
        bytes32 destinationRecipient,
        uint32 destinationChainId,
        uint256 amount,
        uint64 coreNonce,
        bytes calldata data
    ) external;

    /**
     * @notice Deposits tokens with authorization.
     * @param amount The amount of tokens being deposited.
     * @param authValidAfter The timestamp after which the authorization is valid.
     * @param authValidBefore The timestamp before which the authorization is valid.
     * @param authNonce A unique nonce for the authorization.
     * @param v The V value of the signature.
     * @param r The R value of the signature.
     * @param s The S value of the signature.
     * @param destinationDex The destination dex on HyperCore.
     */
    function depositWithAuth(
        uint256 amount,
        uint256 authValidAfter,
        uint256 authValidBefore,
        bytes32 authNonce,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint32 destinationDex
    ) external;
}
