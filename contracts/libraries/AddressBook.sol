// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MultiCaller } from "@uma/core/contracts/common/implementation/MultiCaller.sol";

/**
 * @dev A helper contract for chain adapters that support OFT or XERC20 messaging on L1
 * @dev Handles token => messenger/router mapping storage, as adapters are called via delegatecall and don't have relevant storage space
 */
// todo: MultiCaller or dedicated batchSetOFTMessenger function? Or both? Multicaller looks cleaner, but batch function is more gas-efficient
contract AddressBook is Ownable, MultiCaller {
    mapping(uint256 => mapping(address => address)) public oftMessengers;

    event OFTMessengerSet(uint256 indexed adapterId, address indexed token, address messenger);

    function setOFTMessenger(
        uint256 adapterId,
        address _token,
        address _messenger
    ) external onlyOwner {
        oftMessengers[adapterId][_token] = _messenger;
        emit OFTMessengerSet(adapterId, _token, _messenger);
    }
}
