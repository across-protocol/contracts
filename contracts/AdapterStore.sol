// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

library MessengerTypes {
    bytes32 public constant OFT_MESSENGER = bytes32("OFT_MESSENGER");
    bytes32 public constant HYP_XERC20_ROUTER = bytes32("HYP_XERC20_ROUTER");
}

/**
 * @dev A helper contract for chain adapters that support OFT or XERC20 messaging(via Hyperlane) on L1
 * @dev Handles token => messenger/router mapping storage, as adapters are called via delegatecall and don't have relevant storage space
 */
contract AdapterStore is Ownable {
    // (messengerType, l2ChainId, l1Token) => messenger address
    mapping(bytes32 => mapping(uint256 => mapping(address => address))) public crossChainMessengers;

    event MessengerSet(
        bytes32 indexed messengerType,
        uint256 indexed l2ChainId,
        address indexed l1Token,
        address messenger
    );

    error ArrayLengthMismatch();

    function setMessenger(
        bytes32 messengerType,
        uint256 l2ChainId,
        address l1Token,
        address messenger
    ) external onlyOwner {
        _setMessenger(messengerType, l2ChainId, l1Token, messenger);
    }

    function batchSetMessengers(
        bytes32 messengerType,
        uint256[] calldata l2ChainIds,
        address[] calldata l1Tokens,
        address[] calldata messengers
    ) external onlyOwner {
        if (l2ChainIds.length != l1Tokens.length || l2ChainIds.length != messengers.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < l2ChainIds.length; i++) {
            _setMessenger(messengerType, l2ChainIds[i], l1Tokens[i], messengers[i]);
        }
    }

    function _setMessenger(
        bytes32 _messengerType,
        uint256 _l2ChainId,
        address _l1Token,
        address _messenger
    ) internal {
        crossChainMessengers[_messengerType][_l2ChainId][_l1Token] = _messenger;
        emit MessengerSet(_messengerType, _l2ChainId, _l1Token, _messenger);
    }
}
