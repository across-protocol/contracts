// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IOFT } from "../interfaces/IOFT.sol";

/**
 * @dev A helper contract for chain adapters that support OFT or XERC20 messaging on L1
 * @dev Handles token => messenger/router mapping storage, as adapters are called via delegatecall and don't have relevant storage space
 */
contract AdapterStore is Ownable {
    mapping(uint256 => mapping(address => address)) public oftMessengers;

    event OFTMessengerSet(uint256 indexed adapterDstId, address indexed l1Token, address oftMessenger);

    error OFTTokenMismatch();
    error ArrayLengthMismatch();

    function setOFTMessenger(
        uint256 adapterDstId,
        address l1Token,
        address oftMessenger
    ) external onlyOwner {
        _setOFTMessenger(adapterDstId, l1Token, oftMessenger);
    }

    function batchSetOFTMessenger(
        uint256[] calldata adapterIds,
        address[] calldata tokens,
        address[] calldata messengers
    ) external onlyOwner {
        if (adapterIds.length != tokens.length || adapterIds.length != messengers.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < adapterIds.length; i++) {
            _setOFTMessenger(adapterIds[i], tokens[i], messengers[i]);
        }
    }

    function _setOFTMessenger(
        uint256 _adapterChainId,
        address _l1Token,
        address _oftMessenger
    ) internal {
        if (IOFT(_oftMessenger).token() != _l1Token) {
            revert OFTTokenMismatch();
        }
        oftMessengers[_adapterChainId][_l1Token] = _oftMessenger;
        emit OFTMessengerSet(_adapterChainId, _l1Token, _oftMessenger);
    }
}
