// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./Base_Adapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Sends cross chain messages Optimism L2 network.
 * @dev This contract's owner should be set to the BridgeAdmin deployed on the same L1 network so that only the
 * BridgeAdmin can call cross-chain administrative functions on the L2 SpokePool via this messenger.
 */
contract Mock_Adapter is Base_Adapter {
    event RelayMessageCalled(address target, bytes message, address caller);

    event RelayTokensCalled(address l1Token, address l2Token, uint256 amount, address to, address caller);

    function relayMessage(address target, bytes memory message) external payable override onlyHubPool {
        emit RelayMessageCalled(target, message, msg.sender);
    }

    constructor(address _hubPool) Base_Adapter(_hubPool) {}

    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override onlyHubPool {
        emit RelayTokensCalled(l1Token, l2Token, amount, to, msg.sender);
        // Pull the tokens from the caller to mock the actions of an L1 bridge pulling tokens.
        IERC20(l1Token).transferFrom(msg.sender, address(this), amount);
    }
}
