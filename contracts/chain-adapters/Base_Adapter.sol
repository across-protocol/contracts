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

import "./libraries/CCTPAdapter.sol";
import "../external/interfaces/CCTPInterfaces.sol";

/**
 * @notice Contract containing logic to send messages from L1 to Base. This is a modified version of the Optimism adapter
 * that excludes the custom bridging logic.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 */

// solhint-disable-next-line contract-name-camelcase
contract Base_Adapter is CrossDomainEnabled, AdapterInterface, CCTPAdapter {
    using SafeERC20 for IERC20;
    uint32 public immutable l2GasLimit = 200_000;

    WETH9Interface public immutable l1Weth;

    IL1StandardBridge public immutable l1StandardBridge;

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _crossDomainMessenger XDomainMessenger Base system contract.
     * @param _l1StandardBridge Standard bridge contract.
     * @param _l1Usdc USDC address on L1.
     * @param _circleDomain Circle domain set for this chain. NOTE: this is issued by circle and is irrelevant of chain id
     * @param _tokenMessenger TokenMessenger contract to bridge via CCTP.
     */
    constructor(
        WETH9Interface _l1Weth,
        address _crossDomainMessenger,
        IL1StandardBridge _l1StandardBridge,
        IERC20 _l1Usdc,
        uint32 _circleDomain,
        ITokenMessenger _tokenMessenger
    ) CrossDomainEnabled(_crossDomainMessenger) CCTPAdapter(_l1Usdc, _circleDomain, _tokenMessenger) {
        l1Weth = _l1Weth;
        l1StandardBridge = _l1StandardBridge;
    }

    /**
     * @notice Send cross-chain message to target on Base.
     * @param target Contract on Base that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        sendCrossDomainMessage(target, uint32(l2GasLimit), message);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Base.
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
        }
        // If the l1Token is USDC, then we send it to the CCTP bridge
        else if (_isL1Usdc(l1Token)) {
            _transferFromL1Usdc(to, amount);
        } else {
            IL1StandardBridge _l1StandardBridge = l1StandardBridge;

            IERC20(l1Token).safeIncreaseAllowance(address(_l1StandardBridge), amount);
            _l1StandardBridge.depositERC20To(l1Token, l2Token, to, amount, l2GasLimit, "");
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
