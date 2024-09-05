// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts5/token/ERC20/ERC20.sol";

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

contract DepositManagerMock {
    function depositERC20ForUser(
        address token,
        address user,
        uint256 amount // solhint-disable-next-line no-empty-blocks
    ) external {} // solhint-disable-line no-empty-blocks
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
