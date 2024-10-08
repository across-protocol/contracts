// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

// @dev Use local modified CrossDomainEnabled contract instead of one exported by eth-optimism because we need
// this contract's state variables to be `immutable` because of the delegateCall call.
import "./CrossDomainEnabled.sol";
import "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../libraries/CircleCCTPAdapter.sol";
import "../external/interfaces/CCTPInterfaces.sol";

/**
 * @notice Contract containing logic to send messages from L1 to World Chain. This is a clone of the Base/Mode adapter
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract WorldChain_Adapter is CrossDomainEnabled, AdapterInterface, CircleCCTPAdapter {
    using SafeERC20 for IERC20;
    uint32 public constant L2_GAS_LIMIT = 200_000;

    WETH9Interface public immutable L1_WETH;

    IL1StandardBridge public immutable L1_STANDARD_BRIDGE;

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _crossDomainMessenger XDomainMessenger World Chain system contract.
     * @param _l1StandardBridge Standard bridge contract.
     * @param _l1Usdc USDC address on L1.
     */
    constructor(
        WETH9Interface _l1Weth,
        address _crossDomainMessenger,
        IL1StandardBridge _l1StandardBridge,
        IERC20 _l1Usdc
    )
        CrossDomainEnabled(_crossDomainMessenger)
        CircleCCTPAdapter(
            _l1Usdc,
            // Hardcode cctp messenger to 0x0 to disable CCTP bridging.
            ITokenMessenger(address(0)),
            CircleDomainIds.UNINTIALIZED
        )
    {
        L1_WETH = _l1Weth;
        L1_STANDARD_BRIDGE = _l1StandardBridge;
    }

    /**
     * @notice Send cross-chain message to target on World Chain.
     * @param target Contract on World Chain that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        sendCrossDomainMessage(target, L2_GAS_LIMIT, message);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to World Chain.
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
        if (l1Token == address(L1_WETH)) {
            L1_WETH.withdraw(amount);
            L1_STANDARD_BRIDGE.depositETHTo{ value: amount }(to, L2_GAS_LIMIT, "");
        }
        // Check if this token is USDC, which requires a custom bridge via CCTP.
        else if (_isCCTPEnabled() && l1Token == address(usdcToken)) {
            _transferUsdc(to, amount);
        } else {
            IL1StandardBridge _l1StandardBridge = L1_STANDARD_BRIDGE;

            IERC20(l1Token).safeIncreaseAllowance(address(_l1StandardBridge), amount);
            _l1StandardBridge.depositERC20To(l1Token, l2Token, to, amount, L2_GAS_LIMIT, "");
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
