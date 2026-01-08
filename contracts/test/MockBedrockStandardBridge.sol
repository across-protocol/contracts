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

    // Enhanced events with all parameters for detailed test verification
    event DepositERC20ToCalled(
        address indexed l1Token,
        address indexed l2Token,
        address to,
        uint256 amount,
        uint32 l2Gas,
        bytes data
    );
    event DepositETHToCalled(address indexed to, uint32 l2Gas, bytes data);

    // Call counters for test assertions
    uint256 public depositERC20ToCallCount;
    uint256 public depositETHToCallCount;

    function depositERC20To(
        address l1Token,
        address l2Token,
        address to,
        uint256 amount,
        uint32 l2Gas,
        bytes calldata data
    ) external {
        depositERC20ToCallCount++;
        IERC20(l1Token).transferFrom(msg.sender, address(this), amount);
        emit ERC20DepositInitiated(to, l1Token, l2Token, amount);
        emit DepositERC20ToCalled(l1Token, l2Token, to, amount, l2Gas, data);
    }

    function depositETHTo(address to, uint32 l2Gas, bytes calldata data) external payable {
        depositETHToCallCount++;
        emit ETHDepositInitiated(to, msg.value);
        emit DepositETHToCalled(to, l2Gas, data);
    }
}

contract MockBedrockCrossDomainMessenger {
    event MessageSent(address indexed target);
    // Enhanced event with all parameters for detailed test verification
    event SendMessageCalled(address indexed target, bytes message, uint32 l2Gas);

    // Call counter for test assertions
    uint256 public sendMessageCallCount;

    address private msgSender;

    function sendMessage(address target, bytes calldata message, uint32 l2Gas) external {
        sendMessageCallCount++;
        emit MessageSent(target);
        emit SendMessageCalled(target, message, l2Gas);
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
