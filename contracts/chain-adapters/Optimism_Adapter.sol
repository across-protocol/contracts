// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/AdapterInterface.sol";
import "../interfaces/WETH9.sol";

import "./CrossDomainEnabled.sol";
import "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

import "@uma/core/contracts/common/implementation/Lockable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Contract containing logic to send messages from L1 to Optimism.
 */
contract Optimism_Adapter is CrossDomainEnabled, AdapterInterface {
    using SafeERC20 for IERC20;
    uint32 public immutable l2GasLimit = 5_000_000;

    WETH9 public immutable l1Weth;

    IL1StandardBridge public immutable l1StandardBridge;

    event L2GasLimitSet(uint32 newGasLimit);

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _crossDomainMessenger XDomainMessenger Optimism system contract.
     * @param _l1StandardBridge Standard bridge contract.
     */
    constructor(
        WETH9 _l1Weth,
        address _crossDomainMessenger,
        IL1StandardBridge _l1StandardBridge
    ) CrossDomainEnabled(_crossDomainMessenger) {
        l1Weth = _l1Weth;
        l1StandardBridge = _l1StandardBridge;
    }

    /**
     * @notice Send cross-chain message to target on Optimism.
     * @param target Contract on Optimism that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        sendCrossDomainMessage(target, uint32(l2GasLimit), message);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Optimism.
     * @param l1Token L1 token to deposit.
     * @param l2Token L2 token to receive.
     * @param amount Amount of L1 tokens to deposit and L2 tokens to receive.
     * @param to Bridge recipient.
     */
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
            IERC20(l1Token).safeIncreaseAllowance(address(l1StandardBridge), amount);
            l1StandardBridge.depositERC20To(l1Token, l2Token, to, amount, l2GasLimit, "");
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
