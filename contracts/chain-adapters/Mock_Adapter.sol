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

    Mock_Bridge public bridge;

    constructor(address _hubPool) Base_Adapter(_hubPool) {
        bridge = new Mock_Bridge();
    }

    function relayMessage(address target, bytes memory message) external payable override {
        bridge.bridgeMessage(target, message);
        emit RelayMessageCalled(target, message, msg.sender);
    }

    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override {
        IERC20(l1Token).approve(address(bridge), amount);
        bridge.bridgeTokens(l1Token, amount);
        emit RelayTokensCalled(l1Token, l2Token, amount, to, msg.sender);
    }
}

// This contract is intended to "act like" a simple version of an L2 bridge.
// It's primarily meant to better reflect how a true L2 bridge interaction might work to give better gas estimates.
contract Mock_Bridge {
    event BridgedTokens(address token, uint256 amount);
    event BridgedMessage(address target, bytes message);

    mapping(address => uint256) deposits;

    function bridgeTokens(address token, uint256 amount) public {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        deposits[token] += amount;
        emit BridgedTokens(token, amount);
    }

    function bridgeMessage(address target, bytes memory message) public {
        emit BridgedMessage(target, message);
    }
}
