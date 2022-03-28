// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

contract ArbitrumMockErc20GatewayRouter {
    function outboundTransfer(
        address,
        address,
        uint256,
        uint256,
        uint256,
        bytes calldata _data
    ) external payable returns (bytes memory) {
        return _data;
    }

    function getGateway(address) external view returns (address) {
        return address(this);
    }
}
