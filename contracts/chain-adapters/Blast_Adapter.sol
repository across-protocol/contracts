// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

// @dev Use local modified CrossDomainEnabled contract instead of one exported by eth-optimism because we need
// this contract's state variables to be `immutable` because of the delegateCall call.
import "./CrossDomainEnabled.sol";
import "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import "@eth-optimism/contracts/L1/messaging/IL1ERC20Bridge.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../libraries/CircleCCTPAdapter.sol";
import "../external/interfaces/CCTPInterfaces.sol";

/**
 * @notice Contract containing logic to send messages from L1 to Blast. This is a modified version of the Optimism adapter
 * that excludes the custom bridging logic. It differs from the Base Adapter in that it uses a special
 * Blast contract to bridge WETH and DAI, which are yielding rebasing tokens on L2, WETH and USDB.
 */

// solhint-disable-next-line contract-name-camelcase
contract Blast_Adapter is CrossDomainEnabled, AdapterInterface, CircleCCTPAdapter {
    using SafeERC20 for IERC20;
    uint32 public constant L2_GAS_LIMIT = 200_000;

    WETH9Interface public immutable L1_WETH;

    IL1StandardBridge public immutable L1_STANDARD_BRIDGE;

    // Bridge used to get yielding version of ERC20's on L2.
    address private L1_BLAST_BRIDGE = 0x3a05E5d33d7Ab3864D53aaEc93c8301C1Fa49115;
    address private L1_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _crossDomainMessenger XDomainMessenger Blast system contract.
     * @param _l1StandardBridge Standard bridge contract.
     * @param _l1Usdc USDC address on L1.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     */
    constructor(
        WETH9Interface _l1Weth,
        address _crossDomainMessenger,
        IL1StandardBridge _l1StandardBridge,
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger
    ) CrossDomainEnabled(_crossDomainMessenger) CircleCCTPAdapter(_l1Usdc, _cctpTokenMessenger, CircleDomainIds.Base) {
        L1_WETH = _l1Weth;
        L1_STANDARD_BRIDGE = _l1StandardBridge;
    }

    /**
     * @notice Send cross-chain message to target on Base.
     * @param target Contract on Base that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        sendCrossDomainMessage(target, L2_GAS_LIMIT, message);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Blast.
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
        // If token can be bridged into yield-ing version of ERC20 on L2 side, then use Blast Bridge, otherwise
        // use standard bridge.

        // If the l1Token is weth then unwrap it to ETH then send the ETH to the blast bridge.
        if (l1Token == address(L1_WETH)) {
            L1_WETH.withdraw(amount);
            // @dev: we can use the standard or the blast bridge to deposit ETH here:
            L1_STANDARD_BRIDGE.depositETHTo{ value: amount }(to, L2_GAS_LIMIT, "");
        }
        // Check if this token is DAI, then use the L1 Blast Bridge
        else if (l1Token == L1_DAI) {
            IL1ERC20Bridge(L1_BLAST_BRIDGE).depositERC20To(l1Token, l2Token, to, amount, L2_GAS_LIMIT, "");
        } else {
            IL1StandardBridge _l1StandardBridge = L1_STANDARD_BRIDGE;

            IERC20(l1Token).safeIncreaseAllowance(address(_l1StandardBridge), amount);
            _l1StandardBridge.depositERC20To(l1Token, l2Token, to, amount, L2_GAS_LIMIT, "");
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
