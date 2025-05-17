// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

library MessengerTypes {
    bytes32 public constant OFT_MESSENGER = bytes32("OFT_MESSENGER");
}

/**
 * @dev A helper contract for chain adapters on the hub chain that support OFT messaging. Handles
 * @dev token => messenger mapping storage. Adapters can't store this themselves as they're called
 * @dev via `delegateCall` and their storage is not part of available context.
 */
contract AdapterStore is Ownable {
    // (messengerType, dstDomainId, srcChainToken) => messenger address
    mapping(bytes32 => mapping(uint256 => mapping(address => address))) public crossChainMessengers;

    event MessengerSet(
        bytes32 indexed messengerType,
        uint256 indexed dstDomainId,
        address indexed srcChainToken,
        address srcChainMessenger
    );

    error ArrayLengthMismatch();

    function setMessenger(
        bytes32 messengerType,
        uint256 dstDomainId,
        address srcChainToken,
        address srcChainMessenger
    ) external onlyOwner {
        _setMessenger(messengerType, dstDomainId, srcChainToken, srcChainMessenger);
    }

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

    function _setMessenger(
        bytes32 _messengerType,
        uint256 _dstDomainId,
        address _srcChainToken,
        address _srcChainMessenger
    ) internal {
        crossChainMessengers[_messengerType][_dstDomainId][_srcChainToken] = _srcChainMessenger;
        emit MessengerSet(_messengerType, _dstDomainId, _srcChainToken, _srcChainMessenger);
    }
}
