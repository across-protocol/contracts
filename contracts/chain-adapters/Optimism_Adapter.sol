// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@eth-optimism/contracts/libraries/bridge/CrossDomainEnabled.sol";
import "./AdapterInterface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice Sends cross chain messages Optimism L2 network.
 * @dev This contract's owner should be set to the BridgeAdmin deployed on the same L1 network so that only the
 * BridgeAdmin can call cross-chain administrative functions on the L2 DepositBox via this messenger.
 */
contract Optimism_Messenger is Ownable, CrossDomainEnabled, AdapterInterface {
    uint32 public gasLimit;

    constructor(uint32 _gasLimit, address _crossDomainMessenger) CrossDomainEnabled(_crossDomainMessenger) {
        gasLimit = _gasLimit;
    }

    function relayMessage(address target, bytes memory message) external payable override onlyOwner {
        sendCrossDomainMessage(target, uint32(gasLimit), message);
    }

    function relayTokens(
        address tokenAddress,
        uint256 tokenSendAmount,
        address to
    ) external payable override onlyOwner {
        // TODO: Implement
    }
}
