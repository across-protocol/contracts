// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./Base_Adapter.sol";
import "../interfaces/AdapterInterface.sol";
import "../interfaces/WETH9.sol";

import "@eth-optimism/contracts/libraries/bridge/CrossDomainEnabled.sol";
import "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

import "@uma/core/contracts/common/implementation/Lockable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Sends cross chain messages Optimism L2 network.
 * @dev This contract's owner should be set to the some multisig or admin contract. The Owner can simply set the L2 gas
 * and the HubPool. The HubPool is the only contract that can relay tokens and messages over the bridge.
 */
contract Optimism_Adapter is Base_Adapter, CrossDomainEnabled, Lockable {
    uint32 public l2GasLimit = 5_000_000;

    WETH9 public l1Weth;

    IL1StandardBridge public l1StandardBridge;

    event L2GasLimitSet(uint32 newGasLimit);

    constructor(
        WETH9 _l1Weth,
        address _hubPool,
        address _crossDomainMessenger,
        IL1StandardBridge _l1StandardBridge
    ) CrossDomainEnabled(_crossDomainMessenger) Base_Adapter(_hubPool) {
        l1Weth = _l1Weth;
        l1StandardBridge = _l1StandardBridge;
    }

    function setL2GasLimit(uint32 _l2GasLimit) public onlyOwner {
        l2GasLimit = _l2GasLimit;
        emit L2GasLimitSet(l2GasLimit);
    }

    function relayMessage(address target, bytes memory message) external payable override nonReentrant onlyHubPool {
        sendCrossDomainMessage(target, uint32(l2GasLimit), message);
        emit MessageRelayed(target, message);
    }

    // todo: try making this delegate call
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override nonReentrant onlyHubPool {
        // If the l1Token is weth then unwrap it to ETH then send the ETH to the standard bridge.
        if (l1Token == address(l1Weth)) {
            l1Weth.withdraw(amount);
            l1StandardBridge.depositETHTo{ value: amount }(to, l2GasLimit, "");
        } else {
            IERC20(l1Token).approve(address(l1StandardBridge), amount);
            l1StandardBridge.depositERC20To(l1Token, l2Token, to, amount, l2GasLimit, "");
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }

    // Added to enable the Optimism_Adapter to receive ETH. used when unwrapping WETH.
    receive() external payable {}
}
