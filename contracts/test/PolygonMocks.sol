// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

contract RootChainManagerMock {
    function depositEtherFor(address user) external payable {} // solhint-disable-line no-empty-blocks

    function depositFor(
        address user,
        address rootToken,
        bytes calldata depositData
    ) external {} // solhint-disable-line no-empty-blocks
}

contract FxStateSenderMock {
    // solhint-disable-next-line no-empty-blocks
    function sendMessageToChild(address _receiver, bytes calldata _data) external {}
}
