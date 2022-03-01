// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

contract RootChainManagerMock {
    function depositEtherFor(address user) external payable {}

    function depositFor(
        address user,
        address rootToken,
        bytes calldata depositData
    ) external {}
}

contract FxStateSenderMock {
    function sendMessageToChild(address _receiver, bytes calldata _data) external {}
}
