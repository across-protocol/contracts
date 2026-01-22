// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";

contract RootChainManagerMock {
    // Call tracking for depositEtherFor
    uint256 public depositEtherForCallCount;
    struct DepositEtherForCall {
        address user;
        uint256 value;
    }
    DepositEtherForCall public lastDepositEtherForCall;

    // Call tracking for depositFor
    uint256 public depositForCallCount;
    struct DepositForCall {
        address user;
        address rootToken;
        bytes depositData;
    }
    DepositForCall public lastDepositForCall;

    function depositEtherFor(address user) external payable {
        depositEtherForCallCount++;
        lastDepositEtherForCall = DepositEtherForCall(user, msg.value);
    }

    function depositFor(address user, address rootToken, bytes calldata depositData) external {
        depositForCallCount++;
        lastDepositForCall = DepositForCall(user, rootToken, depositData);
    }
}

contract FxStateSenderMock {
    // Call tracking for sendMessageToChild
    uint256 public sendMessageToChildCallCount;
    struct SendMessageToChildCall {
        address receiver;
        bytes data;
    }
    SendMessageToChildCall public lastSendMessageToChildCall;

    function sendMessageToChild(address _receiver, bytes calldata _data) external {
        sendMessageToChildCallCount++;
        lastSendMessageToChildCall = SendMessageToChildCall(_receiver, _data);
    }
}

contract DepositManagerMock {
    // Call tracking for depositERC20ForUser
    uint256 public depositERC20ForUserCallCount;
    struct DepositERC20ForUserCall {
        address token;
        address user;
        uint256 amount;
    }
    DepositERC20ForUserCall public lastDepositERC20ForUserCall;

    function depositERC20ForUser(address token, address user, uint256 amount) external {
        depositERC20ForUserCallCount++;
        lastDepositERC20ForUserCall = DepositERC20ForUserCall(token, user, amount);
    }
}

contract PolygonRegistryMock {
    // solhint-disable-next-line no-empty-blocks
    function erc20Predicate() external returns (address predicate) {}
}

contract PolygonERC20PredicateMock {
    // solhint-disable-next-line no-empty-blocks
    function startExitWithBurntTokens(bytes calldata data) external {}
}

contract PolygonERC20Mock is ERC20 {
    // solhint-disable-next-line no-empty-blocks
    constructor() ERC20("Test ERC20", "TEST") {}

    // solhint-disable-next-line no-empty-blocks
    function withdraw(uint256 amount) external {}
}
