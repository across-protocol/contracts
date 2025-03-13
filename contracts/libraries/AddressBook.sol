// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IHypXERC20Router } from "./HypXERC20Adapter.sol";

/**
 * @dev A helper contract for chain adapters that support OFT or XERC20 messaging on L1
 * @dev Handles token => messenger/router mapping storage, as adapters are called via delegatecall and don't have relevant storage space
 */
contract AddressBook is Ownable {
    mapping(uint256 => mapping(address => address)) public oftMessengers2;
    mapping(uint256 => mapping(address => address)) public hypXERC20Routers2;

    mapping(address => address) public oftMessengers;
    mapping(address => address) public hypXERC20Routers;

    event OFTMessengerSet(address indexed token, address indexed messenger);
    event HypXERC20RouterSet(address indexed token, address indexed router);

    function setOFTMessenger(address _token, address _messenger) external onlyOwner {
        oftMessengers[_token] = _messenger;
        emit OFTMessengerSet(_token, _messenger);
    }

    function setHypXERC20Router(address _token, address _router) external onlyOwner {
        hypXERC20Routers[_token] = _router;
        emit HypXERC20RouterSet(_token, _router);
    }
}
