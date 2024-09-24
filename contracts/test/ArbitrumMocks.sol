// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

contract ArbitrumMockErc20GatewayRouter {
    function outboundTransferCustomRefund(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        bytes calldata _data
    ) external payable returns (bytes memory) {
        return _data;
    }

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

contract Inbox {
    function createRetryableTicket(
        address,
        uint256,
        uint256,
        address,
        address,
        uint256,
        uint256,
        bytes calldata _data
    ) external returns (uint256) {
        return 0;
    }
}

contract L2GatewayRouter {
    function outboundTransfer(
        address,
        address,
        uint256,
        bytes calldata _data
    ) public payable returns (bytes memory) {}
}
