// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/AdapterInterface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Contract used for testing communication between HubPool and Adapter.
 */
contract Mock_Adapter is AdapterInterface {
    event RelayMessageCalled(address target, bytes message, address caller);

    event RelayTokensCalled(address l1Token, address l2Token, uint256 amount, address to, address caller);

    Mock_Bridge public immutable bridge;

    constructor() {
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

    function bridgeTokens(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        deposits[token] += amount;
        emit BridgedTokens(token, amount);
    }

    function bridgeMessage(address target, bytes memory message) external {
        emit BridgedMessage(target, message);
    }
}
