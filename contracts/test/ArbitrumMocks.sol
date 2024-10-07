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
        bytes memory
    ) external pure returns (uint256) {
        return 0;
    }
}

contract L2GatewayRouter {
    mapping(address => address) l2Tokens;

    event OutboundTransfer(address indexed l1Token, address indexed to, uint256 amount);

    function outboundTransfer(
        address l1Token,
        address to,
        uint256 amount,
        bytes memory
    ) public payable returns (bytes memory) {
        emit OutboundTransfer(l1Token, to, amount);
        return "";
    }

    function calculateL2TokenAddress(address l1Token) external view returns (address) {
        return l2Tokens[l1Token];
    }

    function setL2TokenAddress(address l1Token, address l2Token) external {
        l2Tokens[l1Token] = l2Token;
    }
}
