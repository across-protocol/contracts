// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./Base_Adapter.sol";
import "../interfaces/AdapterInterface.sol";
import "../interfaces/WETH9.sol";

import "@eth-optimism/contracts/libraries/bridge/CrossDomainEnabled.sol";
import "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Sends cross chain messages Optimism L2 network.
 * @dev This contract's owner should be set to the BridgeAdmin deployed on the same L1 network so that only the
 * BridgeAdmin can call cross-chain administrative functions on the L2 SpokePool via this messenger.
 */
contract Optimism_Adapter is Base_Adapter, CrossDomainEnabled {
    uint32 public l2GasLimit = 5_000_000;

    WETH9 l1Weth;

    IL1StandardBridge l1StandardBridge;

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
    }

    function relayMessage(address target, bytes memory message) external payable override onlyHubPool {
        sendCrossDomainMessage(target, uint32(l2GasLimit), message);
    }

    // TODO: we should look into using delegate call as this current implementation assumes the caller transfers the
    // tokens first to this contract. This will work with eth based transfers and for now we'll ignore it.
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override onlyHubPool {
        // If the l1Token is weth then unwrap it to ETH then send the ETH to the standard bridge.
        if (l1Token == address(l1Weth)) {
            l1Weth.withdraw(amount);
            l1StandardBridge.depositETHTo{ value: amount }(to, l2GasLimit, "");
        } else {
            IERC20(l1Token).approve(address(l1StandardBridge), amount);
            l1StandardBridge.depositERC20To(l1Token, l2Token, to, amount, l2GasLimit, "");
        }
    }

    // Added to enable the Optimism_Adapter to receive ETH. used when unwrapping WETH.
    receive() external payable {}
}
