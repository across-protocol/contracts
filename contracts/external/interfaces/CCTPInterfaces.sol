/**
 * Copyright (C) 2015, 2016, 2017 Dapphub
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/**
 * Imported as-is from commit 139d8d0ce3b5531d3c7ec284f89d946dfb720016 of:
 *   * https://github.com/walkerq/evm-cctp-contracts/blob/139d8d0ce3b5531d3c7ec284f89d946dfb720016/src/TokenMessenger.sol
 * Changes applied post-import:
 *   * Removed a majority of code from this contract and converted the needed function signatures in this interface.
 */
interface ITokenMessenger {
    /**
     * @notice Deposits and burns tokens from sender to be minted on destination domain.
     * Emits a `DepositForBurn` event.
     * @dev reverts if:
     * - given burnToken is not supported
     * - given destinationDomain has no TokenMessenger registered
     * - transferFrom() reverts. For example, if sender's burnToken balance or approved allowance
     * to this contract is less than `amount`.
     * - burn() reverts. For example, if `amount` is 0.
     * - MessageTransmitter returns false or reverts.
     * @param amount amount of tokens to burn
     * @param destinationDomain destination domain
     * @param mintRecipient address of mint recipient on destination domain
     * @param burnToken address of contract to burn deposited tokens, on local domain
     * @return _nonce unique nonce reserved by message
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 _nonce);

    /**
     * @notice Minter responsible for minting and burning tokens on the local domain
     * @dev A TokenMessenger stores a TokenMinter contract which extends the TokenController contract.
     * https://github.com/circlefin/evm-cctp-contracts/blob/817397db0a12963accc08ff86065491577bbc0e5/src/TokenMessenger.sol#L110
     * @return minter Token Minter contract.
     */
    function localMinter() external view returns (ITokenMinter minter);
}

interface ITokenMessengerV2 {
    // Source: https://github.com/circlefin/evm-cctp-contracts/blob/63ab1f0ac06ce0793c0bbfbb8d09816bc211386d/src/v2/TokenMessengerV2.sol#L138C1-L166C15
    /**
     * @notice Deposits and burns tokens from sender to be minted on destination domain.
     * Emits a `DepositForBurn` event.
     * @dev reverts if:
     * - given burnToken is not supported
     * - given destinationDomain has no TokenMessenger registered
     * - transferFrom() reverts. For example, if sender's burnToken balance or approved allowance
     * to this contract is less than `amount`.
     * - burn() reverts. For example, if `amount` is 0.
     * - maxFee is greater than or equal to `amount`.
     * - MessageTransmitterV2#sendMessage reverts.
     * @param amount amount of tokens to burn
     * @param destinationDomain destination domain to receive message on
     * @param mintRecipient address of mint recipient on destination domain
     * @param burnToken token to burn `amount` of, on local domain
     * @param destinationCaller authorized caller on the destination domain, as bytes32. If equal to bytes32(0),
     * any address can broadcast the message.
     * @param maxFee maximum fee to pay on the destination domain, specified in units of burnToken
     * @param minFinalityThreshold the minimum finality at which a burn message will be attested to.
     */
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    // Source: https://github.com/circlefin/evm-cctp-contracts/blob/63ab1f0ac06ce0793c0bbfbb8d09816bc211386d/src/v2/TokenMessengerV2.sol#L180C1-L210C15
    /**
     * @notice Deposits and burns tokens from sender to be minted on destination domain.
     * Emits a `DepositForBurn` event.
     * @dev reverts if:
     * - `hookData` is zero-length
     * - `burnToken` is not supported
     * - `destinationDomain` has no TokenMessenger registered
     * - transferFrom() reverts. For example, if sender's burnToken balance or approved allowance
     * to this contract is less than `amount`.
     * - burn() reverts. For example, if `amount` is 0.
     * - maxFee is greater than or equal to `amount`.
     * - MessageTransmitterV2#sendMessage reverts.
     * @param amount amount of tokens to burn
     * @param destinationDomain destination domain to receive message on
     * @param mintRecipient address of mint recipient on destination domain, as bytes32
     * @param burnToken token to burn `amount` of, on local domain
     * @param destinationCaller authorized caller on the destination domain, as bytes32. If equal to bytes32(0),
     * any address can broadcast the message.
     * @param maxFee maximum fee to pay on the destination domain, specified in units of burnToken
     * @param hookData hook data to append to burn message for interpretation on destination domain
     */
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}

/**
 * A TokenMessenger stores a TokenMinter contract which extends the TokenController contract. The TokenController
 * contract has a burnLimitsPerMessage public mapping which can be queried to find the per-message burn limit
 * for a given token:
 * https://github.com/circlefin/evm-cctp-contracts/blob/817397db0a12963accc08ff86065491577bbc0e5/src/TokenMinter.sol#L33
 * https://github.com/circlefin/evm-cctp-contracts/blob/817397db0a12963accc08ff86065491577bbc0e5/src/roles/TokenController.sol#L69C40-L69C60
 *
 */
interface ITokenMinter {
    /**
     * @notice Supported burnable tokens on the local domain
     * local token (address) => maximum burn amounts per message
     * @param token address of token contract
     * @return burnLimit maximum burn amount per message for token
     */
    function burnLimitsPerMessage(address token) external view returns (uint256);
}

/**
 * IMessageTransmitter in CCTP inherits IRelayer and IReceiver, but here we only import sendMessage from IRelayer:
 * https://github.com/circlefin/evm-cctp-contracts/blob/377c9bd813fb86a42d900ae4003599d82aef635a/src/interfaces/IMessageTransmitter.sol#L25
 * https://github.com/circlefin/evm-cctp-contracts/blob/377c9bd813fb86a42d900ae4003599d82aef635a/src/interfaces/IRelayer.sol#L23-L35
 */
interface IMessageTransmitter {
    /**
     * @notice Sends an outgoing message from the source domain.
     * @dev Increment nonce, format the message, and emit `MessageSent` event with message information.
     * @param destinationDomain Domain of destination chain
     * @param recipient Address of message recipient on destination domain as bytes32
     * @param messageBody Raw bytes content of message
     * @return nonce reserved by message
     */
    function sendMessage(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes calldata messageBody
    ) external returns (uint64);
}

interface IMessageTransmitterV2 {
    // Source: https://github.com/circlefin/evm-cctp-contracts/blob/63ab1f0ac06ce0793c0bbfbb8d09816bc211386d/src/v2/MessageTransmitterV2.sol#L176C1-L209C61
    /**
     * @notice Receive a message. Messages can only be broadcast once for a given nonce.
     * The message body of a valid message is passed to the specified recipient for further processing.
     *
     * @dev Attestation format:
     * A valid attestation is the concatenated 65-byte signature(s) of exactly
     * `thresholdSignature` signatures, in increasing order of attester address.
     * ***If the attester addresses recovered from signatures are not in
     * increasing order, signature verification will fail.***
     * If incorrect number of signatures or duplicate signatures are supplied,
     * signature verification will fail.
     *
     * Message Format:
     *
     * Field                        Bytes      Type       Index
     * version                      4          uint32     0
     * sourceDomain                 4          uint32     4
     * destinationDomain            4          uint32     8
     * nonce                        32         bytes32    12
     * sender                       32         bytes32    44
     * recipient                    32         bytes32    76
     * destinationCaller            32         bytes32    108
     * minFinalityThreshold         4          uint32     140
     * finalityThresholdExecuted    4          uint32     144
     * messageBody                  dynamic    bytes      148
     * @param message Message bytes
     * @param attestation Concatenated 65-byte signature(s) of `message`, in increasing order
     * of the attester address recovered from signatures.
     * @return success True, if successful; false, if not
     */
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);
}
