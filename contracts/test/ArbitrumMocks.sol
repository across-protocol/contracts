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
