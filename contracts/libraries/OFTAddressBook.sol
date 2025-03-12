// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @dev A helper contract for chain adapters that support OFT messaging from L1
 * @dev Handles OFT token -> messenger mapping storage, as adapters are called via delegatecall and don't have relevant storage space
 */
contract OFTAddressBook is Ownable {
    mapping(address => address) public oftMessengers;

    event OFTMessengerSet(address indexed token, address indexed messenger);

    function setOFTMessenger(address _token, address _messenger) external onlyOwner {
        oftMessengers[_token] = _messenger;
        emit OFTMessengerSet(_token, _messenger);
    }
}
