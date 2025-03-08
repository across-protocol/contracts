// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IOFT } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { IHypXERC20Router } from "./HypXERC20Adapter.sol";

/**
 * @dev A helper contract for chain adapters that support OFT or XERC20 messaging on L1
 * @dev Handles token => messenger/router mapping storage, as adapters are called via delegatecall and don't have relevant storage space
 */
contract AddressBook is Ownable {
    mapping(IERC20 => IOFT) public oftMessengers;
    mapping(IERC20 => IHypXERC20Router) public hypXERC20Routers;

    event OFTMessengerSet(IERC20 indexed token, IOFT indexed messenger);
    event HypXERC20RouterSet(IERC20 indexed token, IHypXERC20Router indexed router);

    function setOFTMessenger(IERC20 _token, IOFT _messenger) external onlyOwner {
        oftMessengers[_token] = _messenger;
        emit OFTMessengerSet(_token, _messenger);
    }

    function setHypXERC20Router(IERC20 _token, IHypXERC20Router _router) external onlyOwner {
        hypXERC20Routers[_token] = _router;
        emit HypXERC20RouterSet(_token, _router);
    }
}
