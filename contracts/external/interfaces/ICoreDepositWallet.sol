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
 * @dev Source: https://github.com/circlefin/hyperevm-circle-contracts/blob/master/src/interfaces/IForwardDepositReceiver.sol
 */
interface IForwardDepositReceiver {
    /**
     * @notice Deposit tokens for a recipient
     * @param recipient Recipient of the deposit
     * @param amount Amount of tokens to deposit
     * @param destinationId Forwarding-address-specific id used in conjunction with
     * recipient to route the deposit to a specific location.
     */
    function depositFor(
        address recipient,
        uint256 amount,
        uint32 destinationId
    ) external;
}

/**
 * @title ICoreDepositWallet
 * @notice Minimal useful interface for the core deposit wallet
 * @dev Source: https://github.com/circlefin/hyperevm-circle-contracts/blob/master/src/interfaces/ICoreDepositWallet.sol
 */
interface ICoreDepositWallet is IForwardDepositReceiver {
    /**
     * @notice Deposits tokens for the sender.
     * @param amount The amount of tokens being deposited.
     * @param destinationDex The destination dex on HyperCore.
     */
    function deposit(uint256 amount, uint32 destinationDex) external;
}
