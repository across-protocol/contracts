// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IOFT } from "./interfaces/IOFT.sol";
import { IHypXERC20Router } from "./interfaces/IHypXERC20Router.sol";

/**
 * @dev A helper contract for chain adapters that support OFT or XERC20 messaging(via Hyperlane) on L1
 * @dev Handles token => messenger/router mapping storage, as adapters are called via delegatecall and don't have relevant storage space
 */
contract AdapterStore is UUPSUpgradeable, OwnableUpgradeable {
    mapping(uint256 => mapping(address => address)) public oftMessengers;
    mapping(uint256 => mapping(address => address)) public hypXERC20Routers;

    event OFTMessengerSet(uint256 indexed adapterChainId, address indexed l1Token, address oftMessenger);
    event HypXERC20RouterSet(uint256 indexed adapterChainId, address indexed l1Token, address oftMessenger);

    error OFTTokenMismatch();
    error HypTokenMismatch();
    error ArrayLengthMismatch();

    function initialize() public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    function setOFTMessenger(
        uint256 adapterChainId,
        address l1Token,
        address oftMessenger
    ) external onlyOwner {
        _setOFTMessenger(adapterChainId, l1Token, oftMessenger);
    }

    function batchSetOFTMessengers(
        uint256[] calldata adapterChainIds,
        address[] calldata tokens,
        address[] calldata messengers
    ) external onlyOwner {
        if (adapterChainIds.length != tokens.length || adapterChainIds.length != messengers.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < adapterChainIds.length; i++) {
            _setOFTMessenger(adapterChainIds[i], tokens[i], messengers[i]);
        }
    }

    function setHypXERC20Router(
        uint256 adapterChainId,
        address l1Token,
        address hypXERC20Router
    ) external onlyOwner {
        _setHypXERC20Router(adapterChainId, l1Token, hypXERC20Router);
    }

    function batchSetHypXERC20Routers(
        uint256[] calldata adapterChainIds,
        address[] calldata tokens,
        address[] calldata routers
    ) external onlyOwner {
        if (adapterChainIds.length != tokens.length || adapterChainIds.length != routers.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < adapterChainIds.length; i++) {
            _setHypXERC20Router(adapterChainIds[i], tokens[i], routers[i]);
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

    function _setHypXERC20Router(
        uint256 _adapterChainId,
        address _l1Token,
        address _hypXERC20Router
    ) internal {
        if (IHypXERC20Router(_hypXERC20Router).wrappedToken() != _l1Token) {
            revert HypTokenMismatch();
        }

        hypXERC20Routers[_adapterChainId][_l1Token] = _hypXERC20Router;
        emit HypXERC20RouterSet(_adapterChainId, _l1Token, _hypXERC20Router);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
