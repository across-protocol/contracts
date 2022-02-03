// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./AdapterInterface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice Sends cross chain messages Optimism L2 network.
 * @dev This contract's owner should be set to the BridgeAdmin deployed on the same L1 network so that only the
 * BridgeAdmin can call cross-chain administrative functions on the L2 DepositBox via this messenger.
 */
contract Mock_Messenger is Ownable, AdapterInterface {
    event relayMessageCalled(address target, bytes message, address caller);

    event relayTokensCalled(address tokenAddress, uint256 tokenSendAmount, address to, address caller);

    function relayMessage(address target, bytes memory message) external payable override onlyOwner {
        emit relayMessageCalled(target, message, msg.sender);
    }

    function relayTokens(
        address tokenAddress,
        uint256 tokenSendAmount,
        address to
    ) external payable override onlyOwner {
        emit relayTokensCalled(tokenAddress, tokenSendAmount, to, msg.sender);
    }
}
