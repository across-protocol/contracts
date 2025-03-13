// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";
import "../libraries/CircleCCTPAdapter.sol";

import { IMessageService, ITokenBridge, IUSDCBridge } from "../external/interfaces/LineaInterfaces.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Supports sending messages and tokens from L1 to Linea.
 * @custom:security-contact bugs@across.to
 */
// solhint-disable-next-line contract-name-camelcase
contract Linea_Adapter is AdapterInterface, CircleCCTPAdapter {
    using SafeERC20 for IERC20;

    WETH9Interface public immutable L1_WETH;
    IMessageService public immutable L1_MESSAGE_SERVICE;
    ITokenBridge public immutable L1_TOKEN_BRIDGE;

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _l1MessageService Canonical message service contract on L1.
     * @param _l1TokenBridge Canonical token bridge contract on L1.
     */
    constructor(
        WETH9Interface _l1Weth,
        IMessageService _l1MessageService,
        ITokenBridge _l1TokenBridge,
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger
    ) CircleCCTPAdapter(_l1Usdc, _cctpTokenMessenger, CircleDomainIds.Linea) {
        L1_WETH = _l1Weth;
        L1_MESSAGE_SERVICE = _l1MessageService;
        L1_TOKEN_BRIDGE = _l1TokenBridge;
    }

    /**
     * @notice Send cross-chain message to target on Linea.
     * @param target Contract on Linea that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        // Linea currently does not support auto-claiming of cross-chain messages that have
        // non-empty calldata. As we need to manually claim these messages, we can set the
        // message fees to 0.
        L1_MESSAGE_SERVICE.sendMessage(target, 0, message);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Linea.
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
        if (l1Token == address(usdcToken) && _isCCTPEnabled()) {
            _transferUsdc(to, amount);
        }
        // If the l1Token is WETH then unwrap it to ETH then send the ETH directly
        // via the Canoncial Message Service.
        else if (l1Token == address(L1_WETH)) {
            L1_WETH.withdraw(amount);
            L1_MESSAGE_SERVICE.sendMessage{ value: amount }(to, 0, "");
        }
        // For other tokens, we can use the Canonical Token Bridge.
        else {
            IERC20(l1Token).safeIncreaseAllowance(address(L1_TOKEN_BRIDGE), amount);
            L1_TOKEN_BRIDGE.bridgeToken(l1Token, amount, to);
        }

        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
