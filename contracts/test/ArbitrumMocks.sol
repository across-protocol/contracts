// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

contract ArbitrumMockErc20GatewayRouter {
    function outboundTransfer(
        address _token,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory) {
        return _data;
    }

    function getGateway(address _token) external view returns (address) {
        return address(this);
    }
}
