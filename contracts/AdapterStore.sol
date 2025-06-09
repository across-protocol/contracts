// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOFT } from "./interfaces/IOFT.sol";

/**
 * @title MessengerTypes
 * @notice Library containing messenger type constants
 * @custom:security-contact bugs@across.to
 */
library MessengerTypes {
    /** @notice Identifier for OFT (Omni-chain Fungible Token by LayerZero) messenger type */
    bytes32 public constant OFT_MESSENGER = bytes32("OFT_MESSENGER");
}

/**
 * @dev A helper contract for chain adapters on the hub chain that support OFT messaging. Handles
 * @dev token => messenger mapping storage. Adapters can't store this themselves as they're called
 * @dev via `delegateCall` and their storage is not part of available context.
 * @custom:security-contact bugs@across.to
 */
contract AdapterStore is Ownable {
    /** @notice Maps messenger type and destination domain to token-messenger pairs */
    mapping(bytes32 messengerType => mapping(uint256 dstDomainId => mapping(address srcChainToken => address messengerAddress)))
        public crossChainMessengers;

    /**
     * @notice Emitted when a messenger is set for a specific token and destination
     * @param messengerType Type of messenger being set
     * @param dstDomainId Destination domain ID
     * @param srcChainToken Source chain token address
     * @param srcChainMessenger Source chain messenger address
     */
    event MessengerSet(
        bytes32 indexed messengerType,
        uint256 indexed dstDomainId,
        address indexed srcChainToken,
        address srcChainMessenger
    );

    /** @notice Thrown when array lengths don't match in batch operations */
    error ArrayLengthMismatch();

    /** @notice Thrown when IOFT messenger's token doesn't match expected token */
    error IOFTTokenMismatch();

    /** @notice Thrown when messenger type is not supported */
    error NonExistentMessengerType();

    /**
     * @notice Sets a messenger for a specific token and destination domain
     * @param messengerType Type of messenger to set
     * @param dstDomainId Destination domain ID
     * @param srcChainToken Source chain token address
     * @param srcChainMessenger Source chain messenger address
     */
    function setMessenger(
        bytes32 messengerType,
        uint256 dstDomainId,
        address srcChainToken,
        address srcChainMessenger
    ) external onlyOwner {
        _setMessenger(messengerType, dstDomainId, srcChainToken, srcChainMessenger);
    }

    /**
     * @notice Sets multiple messengers in a single transaction
     * @param messengerTypes Array of messenger types
     * @param dstDomainIds Array of destination domain IDs
     * @param srcChainTokens Array of source chain token addresses
     * @param srcChainMessengers Array of source chain messenger addresses
     */
    function batchSetMessengers(
        bytes32[] calldata messengerTypes,
        uint256[] calldata dstDomainIds,
        address[] calldata srcChainTokens,
        address[] calldata srcChainMessengers
    ) external onlyOwner {
        if (
            messengerTypes.length != dstDomainIds.length ||
            messengerTypes.length != srcChainTokens.length ||
            messengerTypes.length != srcChainMessengers.length
        ) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < dstDomainIds.length; i++) {
            _setMessenger(messengerTypes[i], dstDomainIds[i], srcChainTokens[i], srcChainMessengers[i]);
        }
    }

    /**
     * @notice Internal function to set a messenger with validation
     * @param _messengerType Type of messenger to set
     * @param _dstDomainId Destination domain ID
     * @param _srcChainToken Source chain token address
     * @param _srcChainMessenger Source chain messenger address
     */
    function _setMessenger(
        bytes32 _messengerType,
        uint256 _dstDomainId,
        address _srcChainToken,
        address _srcChainMessenger
    ) internal {
        // @dev Always allow zero-messenger to be set: this can be used to 'remove' a stored token <> messenger relationship
        if (_srcChainMessenger != address(0)) {
            if (_messengerType == MessengerTypes.OFT_MESSENGER) {
                // @dev Protect against human error: check that IOFT messenger's token matches the expected one
                if (IOFT(_srcChainMessenger).token() != _srcChainToken) {
                    revert IOFTTokenMismatch();
                }
            } else {
                revert NonExistentMessengerType();
            }
        }
        crossChainMessengers[_messengerType][_dstDomainId][_srcChainToken] = _srcChainMessenger;
        emit MessengerSet(_messengerType, _dstDomainId, _srcChainToken, _srcChainMessenger);
    }
}
