// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IOFT } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

/**
 * @dev A helper contract for chain adapters that support OFT messaging from L1
 * @dev Handles OFT token -> messenger mapping storage, as adapters are called via delegatecall and don't have relevant storage space
 */
contract OFTAddressBook is Ownable {
    mapping(IERC20 => IOFT) public oftMessengers;

    event OFTMessengerSet(IERC20 indexed token, IOFT indexed messenger);

    function setOFTMessenger(IERC20 _token, IOFT _messenger) external onlyOwner {
        oftMessengers[_token] = _messenger;
        emit OFTMessengerSet(_token, _messenger);
    }
}
