// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@scroll-tech/contracts/L1/gateways/IL1GatewayRouter.sol";
import "@scroll-tech/contracts/L1/rollup/IL2GasPriceOracle.sol";
import "@scroll-tech/contracts/L1/IL1ScrollMessenger.sol";
import "./interfaces/AdapterInterface.sol";

/**
 * @title Scroll_Adapter
 * @notice Adapter contract deployed on L1 alongside the HubPool to facilitate token transfers
 * and arbitrary message relaying from L1 to L2.
 * @custom:security-contact bugs@umaproject.org
 */
contract Scroll_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;

    /**
     * @notice Used as the gas limit for relaying messages to L2.
     */
    uint32 public immutable L2_MESSAGE_RELAY_GAS_LIMIT;

    /**
     * @notice Use as the gas limit for relaying tokens to L2.
     */
    uint32 public immutable L2_TOKEN_RELAY_GAS_LIMIT;

    /**
     * @notice The address of the official l1GatewayRouter contract for Scroll for bridging tokens from L1 -> L2
     * @dev We can find these (main/test)net deployments here: https://docs.scroll.io/en/developers/scroll-contracts/#scroll-contracts
     */
    IL1GatewayRouter public immutable L1_GATEWAY_ROUTER;

    /**
     * @notice The address of the official messenger contract for Scroll from L1 -> L2
     * @dev We can find these (main/test)net deployments here: https://docs.scroll.io/en/developers/scroll-contracts/#scroll-contracts
     */
    IL1ScrollMessenger public immutable L1_SCROLL_MESSENGER;

    /**
     * @notice The address of the official gas price oracle contract for Scroll for estimating the relayer fee
     * @dev We can find these (main/test)net deployments here: https://docs.scroll.io/en/developers/scroll-contracts/#scroll-contracts
     */
    IL2GasPriceOracle public immutable L2_GAS_PRICE_ORACLE;

    /**************************************
     *          PUBLIC FUNCTIONS          *
     **************************************/

    /**
     * @notice Constructs new Adapter.
     * @param _l1GatewayRouter Standard bridge contract.
     * @param _l1ScrollMessenger Scroll Messenger contract.
     * @param _l2GasPriceOracle Gas price oracle contract.
     * @param _l2MessageRelayGasLimit Gas limit for relaying messages to L2.
     * @param _l2TokenRelayGasLimit Gas limit for relaying tokens to L2.
     */
    constructor(
        IL1GatewayRouter _l1GatewayRouter,
        IL1ScrollMessenger _l1ScrollMessenger,
        IL2GasPriceOracle _l2GasPriceOracle,
        uint32 _l2MessageRelayGasLimit,
        uint32 _l2TokenRelayGasLimit
    ) {
        L1_GATEWAY_ROUTER = _l1GatewayRouter;
        L1_SCROLL_MESSENGER = _l1ScrollMessenger;
        L2_GAS_PRICE_ORACLE = _l2GasPriceOracle;
        L2_MESSAGE_RELAY_GAS_LIMIT = _l2MessageRelayGasLimit;
        L2_TOKEN_RELAY_GAS_LIMIT = _l2TokenRelayGasLimit;
    }

    /**
     * @notice Send message to `target` on Scroll.
     * @dev This message is marked payable because relaying the message will require
     * a fee that needs to be propagated to the Scroll Bridge. It will not send msg.value
     * to the target contract on L2.
     * @param target L2 address to send message to.
     * @param message Message to send to `target`.
     */
    function relayMessage(address target, bytes calldata message) external payable {
        // We can specifically send a message with 0 value to the Scroll Bridge
        // and it will not forward any ETH to the target contract on L2. However,
        // we need to set the payable value to msg.value to ensure that the Scroll
        // Bridge has enough gas to forward the message to L2.
        L1_SCROLL_MESSENGER.sendMessage{ value: _generateRelayerFee(L2_MESSAGE_RELAY_GAS_LIMIT) }(
            target,
            0,
            message,
            L2_MESSAGE_RELAY_GAS_LIMIT
        );
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Send `amount` of `l1Token` to `to` on Scroll. `l2Token` is the Scroll address equivalent of `l1Token`.
     * @dev This method is marked payable because relaying the message might require a fee
     * to be paid by the sender to forward the message to L2. However, it will not send msg.value
     * to the target contract on L2.
     * @param l1Token L1 token to bridge.
     * @param l2Token L2 token to receive.
     * @param amount Amount of `l1Token` to bridge.
     * @param to Bridge recipient.
     */
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable {
        IL1GatewayRouter _l1GatewayRouter = L1_GATEWAY_ROUTER;

        // Confirm that the l2Token that we're trying to send is the correct counterpart
        // address
        address _l2Token = _l1GatewayRouter.getL2ERC20Address(l1Token);
        require(_l2Token == l2Token, "l2Token Mismatch");

        IERC20(l1Token).safeIncreaseAllowance(address(_l1GatewayRouter), amount);

        // The scroll bridge handles arbitrary ERC20 tokens and is mindful of
        // the official WETH address on-chain. We don't need to do anything specific
        // to differentiate between WETH and a separate ERC20.
        // Note: This happens due to the L1GatewayRouter.getERC20Gateway() call
        // Note: dev docs: https://docs.scroll.io/en/developers/l1-and-l2-bridging/eth-and-erc20-token-bridge/
        _l1GatewayRouter.depositERC20{ value: _generateRelayerFee(L2_TOKEN_RELAY_GAS_LIMIT) }(
            l1Token,
            to,
            amount,
            L2_TOKEN_RELAY_GAS_LIMIT
        );
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }

    /**************************************
     *         INTERNAL FUNCTIONS         *
     **************************************/

    /**
     * @notice Generates the relayer fee for a message to be sent to L2.
     * @dev Function will revert if the contract does not have enough ETH to pay the fee.
     * @param _l2GasLimit Gas limit for relaying message to L2.
     * @return l2Fee The relayer fee for the message.
     */
    function _generateRelayerFee(uint32 _l2GasLimit) internal view returns (uint256 l2Fee) {
        l2Fee = L2_GAS_PRICE_ORACLE.estimateCrossDomainMessageFee(_l2GasLimit);
        require(address(this).balance >= l2Fee, "Insufficient ETH balance");
    }
}
