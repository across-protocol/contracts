// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@scroll-tech/contracts/libraries/IScrollMessenger.sol";

/**
 * @title MockScrollMessenger
 * @notice Mock implementation of IScrollMessenger for testing Scroll_SpokePool
 */
contract MockScrollMessenger is IScrollMessenger {
    address private _xDomainMessageSender;

    /**
     * @notice Sets the xDomainMessageSender that will be returned by subsequent calls
     * @param sender The address to set as the cross-domain sender
     */
    function setXDomainMessageSender(address sender) external {
        _xDomainMessageSender = sender;
    }

    /**
     * @notice Returns the sender of a cross domain message
     */
    function xDomainMessageSender() external view override returns (address) {
        return _xDomainMessageSender;
    }

    /**
     * @notice Impersonates a cross-domain call by setting the xDomainMessageSender
     *         and calling the target with the provided data
     * @param target The target contract to call
     * @param data The calldata to pass to the target
     */
    function impersonateCall(address target, bytes memory data) external {
        _xDomainMessageSender = msg.sender;
        (bool success, bytes memory returnData) = target.call(data);
        if (!success) {
            // Forward the revert reason
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        _xDomainMessageSender = address(0);
    }

    /**
     * @notice Mock implementation - does nothing
     */
    function sendMessage(address, uint256, bytes calldata, uint256) external payable override {}

    /**
     * @notice Mock implementation - does nothing
     */
    function sendMessage(address, uint256, bytes calldata, uint256, address) external payable override {}
}

/**
 * @title MockScrollL2GatewayRouter
 * @notice Mock implementation of IL2GatewayRouterExtended for testing Scroll_SpokePool
 */
contract MockScrollL2GatewayRouter {
    address public defaultERC20Gateway;
    mapping(address => address) public erc20Gateways;

    // Track last withdrawERC20 call for verification
    address public lastWithdrawToken;
    address public lastWithdrawTo;
    uint256 public lastWithdrawAmount;
    uint256 public lastWithdrawGasLimit;

    event WithdrawERC20Called(address indexed token, address indexed to, uint256 amount, uint256 gasLimit);

    constructor() {
        defaultERC20Gateway = address(this);
    }

    /**
     * @notice Sets the default ERC20 gateway address
     */
    function setDefaultERC20Gateway(address gateway) external {
        defaultERC20Gateway = gateway;
    }

    /**
     * @notice Sets a custom gateway for a specific token
     */
    function setERC20Gateway(address token, address gateway) external {
        erc20Gateways[token] = gateway;
    }

    /**
     * @notice Returns the gateway for a specific token, or the default gateway if not set
     */
    function getERC20Gateway(address token) external view returns (address) {
        address gateway = erc20Gateways[token];
        return gateway != address(0) ? gateway : defaultERC20Gateway;
    }

    /**
     * @notice Mock withdrawERC20 - records the call parameters
     */
    function withdrawERC20(address token, address to, uint256 amount, uint256 gasLimit) external payable {
        lastWithdrawToken = token;
        lastWithdrawTo = to;
        lastWithdrawAmount = amount;
        lastWithdrawGasLimit = gasLimit;
        emit WithdrawERC20Called(token, to, amount, gasLimit);
    }
}
