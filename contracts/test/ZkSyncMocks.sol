// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Mock ZkSync ERC20 bridge for testing.
 * @dev Mimics the ZkBridgeLike interface used by ZkSync_SpokePool.
 */
contract MockZkBridge {
    // Call tracking for test assertions (smock-like behavior)
    uint256 public withdrawCallCount;

    event Withdrawal(address indexed l1Receiver, address indexed l2Token, uint256 amount);

    struct WithdrawCall {
        address l1Receiver;
        address l2Token;
        uint256 amount;
    }
    WithdrawCall public lastWithdrawCall;

    // Store all calls for multi-call verification
    WithdrawCall[] public withdrawCalls;

    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external {
        withdrawCallCount++;
        lastWithdrawCall = WithdrawCall(_l1Receiver, _l2Token, _amount);
        withdrawCalls.push(lastWithdrawCall);
        emit Withdrawal(_l1Receiver, _l2Token, _amount);
    }

    /**
     * @notice Get a specific withdraw call by index.
     */
    function getWithdrawCall(
        uint256 index
    ) external view returns (address l1Receiver, address l2Token, uint256 amount) {
        WithdrawCall memory call = withdrawCalls[index];
        return (call.l1Receiver, call.l2Token, call.amount);
    }
}

/**
 * @notice Mock ZkSync L2 ETH contract for testing.
 * @dev Mimics the IL2ETH interface - ETH on ZkSync implements ERC-20 subset with L1 bridge support.
 */
contract MockL2Eth {
    // Call tracking for test assertions (smock-like behavior)
    uint256 public withdrawCallCount;

    event EthWithdrawal(address indexed l1Receiver, uint256 amount);

    struct WithdrawCall {
        address l1Receiver;
        uint256 amount;
    }
    WithdrawCall public lastWithdrawCall;

    // Store all calls for multi-call verification
    WithdrawCall[] public withdrawCalls;

    function withdraw(address _l1Receiver) external payable {
        withdrawCallCount++;
        lastWithdrawCall = WithdrawCall(_l1Receiver, msg.value);
        withdrawCalls.push(lastWithdrawCall);
        emit EthWithdrawal(_l1Receiver, msg.value);
    }

    /**
     * @notice Get a specific withdraw call by index.
     */
    function getWithdrawCall(uint256 index) external view returns (address l1Receiver, uint256 amount) {
        WithdrawCall memory call = withdrawCalls[index];
        return (call.l1Receiver, call.amount);
    }

    // Allow receiving ETH
    receive() external payable {}
}
