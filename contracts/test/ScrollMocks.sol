// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/**
 * @title MockScrollL1Messenger
 * @notice Mock Scroll L1 Messenger for testing Scroll_Adapter.
 * @dev Implements IL1ScrollMessenger.sendMessage and tracks call parameters.
 */
contract MockScrollL1Messenger {
    event MessageSent(address indexed target, uint256 value, bytes message, uint256 gasLimit);

    // Call counter for test assertions
    uint256 public sendMessageCallCount;

    // Last call parameters (similar to smock's calledWith behavior)
    struct SendMessageCall {
        address target;
        uint256 value;
        bytes message;
        uint256 gasLimit;
        uint256 ethValue;
    }
    SendMessageCall public lastSendMessageCall;

    /**
     * @notice Mock sendMessage that tracks call parameters.
     * @param _target L2 address to send message to.
     * @param _value ETH value to send with the message (to target on L2).
     * @param _message Message to send to `target`.
     * @param _gasLimit Gas limit for the L2 execution.
     */
    function sendMessage(address _target, uint256 _value, bytes calldata _message, uint256 _gasLimit) external payable {
        sendMessageCallCount++;
        lastSendMessageCall = SendMessageCall(_target, _value, _message, _gasLimit, msg.value);
        emit MessageSent(_target, _value, _message, _gasLimit);
    }

    // Allow receiving ETH for fee payment
    receive() external payable {}
}

/**
 * @title MockScrollL1GasPriceOracle
 * @notice Mock Scroll L2 Gas Price Oracle for testing Scroll_Adapter.
 * @dev Allows setting a configurable fee to be returned by estimateCrossDomainMessageFee.
 */
contract MockScrollL1GasPriceOracle {
    uint256 public mockedFee;

    /**
     * @notice Sets the mocked fee to be returned by estimateCrossDomainMessageFee.
     * @param _fee The fee to return.
     */
    function setMockedFee(uint256 _fee) external {
        mockedFee = _fee;
    }

    /**
     * @notice Returns the mocked fee for cross-domain message relay.
     * @param /* _gasLimit Gas limit for the message (ignored in mock).
     * @return The mocked fee.
     */
    function estimateCrossDomainMessageFee(uint256 /* _gasLimit */) external view returns (uint256) {
        return mockedFee;
    }
}

/**
 * @title MockScrollL1GatewayRouter
 * @notice Mock Scroll L1 Gateway Router for testing Scroll_Adapter.
 * @dev Tracks depositERC20 calls and provides L2 token address mapping.
 */
contract MockScrollL1GatewayRouter {
    event DepositERC20(address indexed token, address indexed to, uint256 amount, uint256 gasLimit);

    // Call counter for test assertions
    uint256 public depositERC20CallCount;

    // L1 -> L2 token address mapping
    mapping(address => address) public l2TokenMapping;

    // Last call parameters (similar to smock's calledWith behavior)
    struct DepositERC20Call {
        address token;
        address to;
        uint256 amount;
        uint256 gasLimit;
        uint256 ethValue;
    }
    DepositERC20Call public lastDepositERC20Call;

    /**
     * @notice Sets the L2 token address for a given L1 token.
     * @param _l1Token The L1 token address.
     * @param _l2Token The corresponding L2 token address.
     */
    function setL2ERC20Address(address _l1Token, address _l2Token) external {
        l2TokenMapping[_l1Token] = _l2Token;
    }

    /**
     * @notice Returns the L2 token address for a given L1 token.
     * @param _l1Token The L1 token address.
     * @return The corresponding L2 token address.
     */
    function getL2ERC20Address(address _l1Token) external view returns (address) {
        return l2TokenMapping[_l1Token];
    }

    /**
     * @notice Mock depositERC20 that tracks call parameters and pulls tokens.
     * @param _token L1 token to bridge.
     * @param _to Bridge recipient on L2.
     * @param _amount Amount of tokens to bridge.
     * @param _gasLimit Gas limit for the L2 execution.
     */
    function depositERC20(address _token, address _to, uint256 _amount, uint256 _gasLimit) external payable {
        depositERC20CallCount++;
        lastDepositERC20Call = DepositERC20Call(_token, _to, _amount, _gasLimit, msg.value);

        // Pull tokens from sender (mirrors real bridge behavior)
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);

        emit DepositERC20(_token, _to, _amount, _gasLimit);
    }

    // Allow receiving ETH for fee payment
    receive() external payable {}
}
