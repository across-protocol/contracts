// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./Base_Adapter.sol";
import "../interfaces/AdapterInterface.sol";
import "../interfaces/WETH9.sol";

import "@uma/core/contracts/common/implementation/Lockable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Ethereum_Adapter is Base_Adapter, Lockable {
    using SafeERC20 for IERC20;

    constructor(address _hubPool) Base_Adapter(_hubPool) {}

    function relayMessage(address target, bytes memory message) external payable override nonReentrant onlyHubPool {
        _executeCall(target, message);
        emit MessageRelayed(target, message);
    }

    function relayTokens(
        address l1Token,
        address l2Token, // l2Token is unused for ethereum since we are assuming that the HubPool is only deployed
        // on this network.
        uint256 amount,
        address to
    ) external payable override nonReentrant onlyHubPool {
        IERC20(l1Token).safeTransfer(to, amount);
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }

    // Note: this snippet of code is copied from Governor.sol.
    function _executeCall(address to, bytes memory data) private {
        // Note: this snippet of code is copied from Governor.sol and modified to not include any "value" field.
        // solhint-disable-next-line no-inline-assembly

        bool success;
        assembly {
            let inputData := add(data, 0x20)
            let inputDataSize := mload(data)
            // Hardcode value to be 0 for relayed governance calls in order to avoid addressing complexity of bridging
            // value cross-chain.
            success := call(gas(), to, 0, inputData, inputDataSize, 0, 0)
        }
        require(success, "execute call failed");
    }

    receive() external payable {}
}
