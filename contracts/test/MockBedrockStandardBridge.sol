// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../Ovm_SpokePool.sol";

// Provides payable withdrawTo interface introduced on Bedrock
contract MockBedrockL2StandardBridge is IL2ERC20Bridge {
    event ERC20WithdrawalInitiated(address indexed l2Token, address indexed to, uint256 amount);

    function withdrawTo(address _l2Token, address _to, uint256 _amount, uint32, bytes calldata) external payable {
        emit ERC20WithdrawalInitiated(_l2Token, _to, _amount);
    }

    function bridgeERC20To(
        address _localToken,
        address _remoteToken,
        address _to,
        uint256 _amount,
        uint32,
        bytes calldata
    ) external {
        // Check that caller has approved this contract to pull funds, mirroring mainnet's behavior
        IERC20(_localToken).transferFrom(msg.sender, address(this), _amount);
        IERC20(_remoteToken).transfer(_to, _amount);
    }
}

contract MockBedrockL1StandardBridge {
    event ETHDepositInitiated(address indexed to, uint256 amount);
    event ERC20DepositInitiated(address indexed to, address l1Token, address l2Token, uint256 amount);

    // Call counters for test assertions
    uint256 public depositERC20ToCallCount;
    uint256 public depositETHToCallCount;

    // Last call parameters (similar to smock's calledWith behavior)
    struct DepositERC20ToCall {
        address l1Token;
        address l2Token;
        address to;
        uint256 amount;
        uint32 l2Gas;
        bytes data;
    }
    DepositERC20ToCall public lastDepositERC20ToCall;

    struct DepositETHToCall {
        address to;
        uint256 value;
        uint32 l2Gas;
        bytes data;
    }
    DepositETHToCall public lastDepositETHToCall;

    function depositERC20To(
        address l1Token,
        address l2Token,
        address to,
        uint256 amount,
        uint32 l2Gas,
        bytes calldata data
    ) external {
        depositERC20ToCallCount++;
        lastDepositERC20ToCall = DepositERC20ToCall(l1Token, l2Token, to, amount, l2Gas, data);
        IERC20(l1Token).transferFrom(msg.sender, address(this), amount);
        emit ERC20DepositInitiated(to, l1Token, l2Token, amount);
    }

    function depositETHTo(address to, uint32 l2Gas, bytes calldata data) external payable {
        depositETHToCallCount++;
        lastDepositETHToCall = DepositETHToCall(to, msg.value, l2Gas, data);
        emit ETHDepositInitiated(to, msg.value);
    }
}

contract MockBedrockCrossDomainMessenger {
    event MessageSent(address indexed target);

    // Call counter for test assertions
    uint256 public sendMessageCallCount;

    // Last call parameters (similar to smock's calledWith behavior)
    struct SendMessageCall {
        address target;
        bytes message;
        uint32 l2Gas;
    }
    SendMessageCall public lastSendMessageCall;

    address private msgSender;

    function sendMessage(address target, bytes calldata message, uint32 l2Gas) external {
        sendMessageCallCount++;
        lastSendMessageCall = SendMessageCall(target, message, l2Gas);
        emit MessageSent(target);
    }

    // Impersonates making a call on L2 from L1.
    function impersonateCall(address target, bytes memory data) external payable returns (bytes memory) {
        msgSender = msg.sender;
        (bool success, bytes memory returnData) = target.call{ value: msg.value }(data);

        // Revert if call reverted.
        if (!success) {
            assembly {
                revert(add(32, returnData), mload(returnData))
            }
        }
        return returnData;
    }

    function xDomainMessageSender() external view returns (address) {
        return msgSender;
    }
}
