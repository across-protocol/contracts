// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/AdapterInterface.sol";
import "../interfaces/WETH9.sol";

import "./CrossDomainEnabled.sol";
import "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

import "@uma/core/contracts/common/implementation/Lockable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Sends cross chain messages Optimism L2 network.
 * @dev This contract's owner should be set to the some multisig or admin contract. The Owner can simply set the L2 gas
 * and the HubPool. The HubPool is the only contract that can relay tokens and messages over the bridge.
 */
contract Optimism_Adapter is CrossDomainEnabled, AdapterInterface {
    uint32 public immutable l2GasLimit = 5_000_000;

    WETH9 public immutable l1Weth;

    IL1StandardBridge public immutable l1StandardBridge;

    event L2GasLimitSet(uint32 newGasLimit);

    constructor(
        WETH9 _l1Weth,
        address _crossDomainMessenger,
        IL1StandardBridge _l1StandardBridge
    ) CrossDomainEnabled(_crossDomainMessenger) {
        l1Weth = _l1Weth;
        l1StandardBridge = _l1StandardBridge;
    }

    function relayMessage(address target, bytes memory message) external payable override {
        sendCrossDomainMessage(target, uint32(l2GasLimit), message);
        emit MessageRelayed(target, message);
    }

    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override {
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
}
