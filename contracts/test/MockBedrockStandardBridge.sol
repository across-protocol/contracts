// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../Ovm_SpokePool.sol";

// Provides payable withdrawTo interface introduced on Bedrock
contract MockBedrockL2StandardBridge is IL2ERC20Bridge {
    event ERC20WithdrawalInitiated(address indexed l2Token, address indexed to, uint256 amount);

    function withdrawTo(
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32,
        bytes calldata
    ) external payable {
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

    function depositERC20To(
        address l1Token,
        address l2Token,
        address to,
        uint256 amount,
        uint32,
        bytes calldata
    ) external {
        IERC20(l1Token).transferFrom(msg.sender, address(this), amount);
        emit ERC20DepositInitiated(to, l1Token, l2Token, amount);
    }

    function depositETHTo(
        address to,
        uint32,
        bytes calldata
    ) external payable {
        emit ETHDepositInitiated(to, msg.value);
    }
}

contract MockBedrockCrossDomainMessenger {
    event MessageSent(address indexed target);

    address private msgSender;

    function sendMessage(
        address target,
        bytes calldata,
        uint32
    ) external {
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
