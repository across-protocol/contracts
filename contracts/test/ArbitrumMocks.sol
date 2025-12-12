// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

contract ArbitrumMockErc20GatewayRouter {
    address public gateway;

    event OutboundTransferCalled(
        address l1Token,
        address to,
        uint256 amount,
        uint256 maxGas,
        uint256 gasPriceBid,
        bytes data
    );

    event OutboundTransferCustomRefundCalled(
        address l1Token,
        address refundTo,
        address to,
        uint256 amount,
        uint256 maxGas,
        uint256 gasPriceBid,
        bytes data
    );

    function setGateway(address _gateway) external {
        gateway = _gateway;
    }

    function outboundTransferCustomRefund(
        address _l1Token,
        address _refundTo,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory) {
        emit OutboundTransferCustomRefundCalled(_l1Token, _refundTo, _to, _amount, _maxGas, _gasPriceBid, _data);
        return _data;
    }

    function outboundTransfer(
        address _l1Token,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory) {
        emit OutboundTransferCalled(_l1Token, _to, _amount, _maxGas, _gasPriceBid, _data);
        return _data;
    }

    function getGateway(address) external view returns (address) {
        // Return custom gateway if set, otherwise return self (original behavior)
        return gateway != address(0) ? gateway : address(this);
    }
}

contract Inbox {
    event RetryableTicketCreated(
        address destAddr,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 maxGas,
        uint256 gasPriceBid,
        bytes data
    );

    function createRetryableTicket(
        address _destAddr,
        uint256 _l2CallValue,
        uint256 _maxSubmissionCost,
        address _excessFeeRefundAddress,
        address _callValueRefundAddress,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes memory _data
    ) external payable returns (uint256) {
        emit RetryableTicketCreated(
            _destAddr,
            _l2CallValue,
            _maxSubmissionCost,
            _excessFeeRefundAddress,
            _callValueRefundAddress,
            _maxGas,
            _gasPriceBid,
            _data
        );
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
