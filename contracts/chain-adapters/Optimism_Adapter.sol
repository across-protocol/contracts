// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";
import "../libraries/CircleCCTPAdapter.sol";
import "../external/interfaces/CCTPInterfaces.sol";

// @dev Use local modified CrossDomainEnabled contract instead of one exported by eth-optimism because we need
// this contract's state variables to be `immutable` because of the delegateCall call.
import "./CrossDomainEnabled.sol";
import "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

import "@openzeppelin/contracts5/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts5/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Interface for Synthetix custom bridge to Optimism.
 */
interface SynthetixBridgeToOptimism is IL1StandardBridge {
    /**
     * @notice Send tokens to Optimism.
     * @param to Address to send tokens to on L2.
     * @param amount Amount of tokens to send.
     */
    function depositTo(address to, uint256 amount) external;
}

/**
 * @notice Contract containing logic to send messages from L1 to Optimism.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore it's only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Optimism_Adapter is CrossDomainEnabled, AdapterInterface, CircleCCTPAdapter {
    using SafeERC20 for IERC20;
    uint32 public constant L2_GAS_LIMIT = 200_000;

    WETH9Interface public immutable L1_WETH;

    IL1StandardBridge public immutable L1_STANDARD_BRIDGE;

    // Optimism has the ability to support "custom" bridges. These bridges are not supported by the canonical bridge
    // and so we need to store the address of the custom token and the associated bridge. In the event we want to
    // support a new token that is not supported by Optimism, we can add a new custom bridge for it and re-deploy the
    // adapter. A full list of custom optimism tokens and their associated bridges can be found here:
    // https://github.com/ethereum-optimism/ethereum-optimism.github.io/blob/master/optimism.tokenlist.json
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant DAI_OPTIMISM_BRIDGE = 0x10E6593CDda8c58a1d0f14C5164B376352a55f2F;
    address public constant SNX = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;
    address public constant SNX_OPTIMISM_BRIDGE = 0x39Ea01a0298C315d149a490E34B59Dbf2EC7e48F;

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _crossDomainMessenger XDomainMessenger Optimism system contract.
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
    )
        CrossDomainEnabled(_crossDomainMessenger)
        CircleCCTPAdapter(_l1Usdc, _cctpTokenMessenger, CircleDomainIds.Optimism)
    {
        L1_WETH = _l1Weth;
        L1_STANDARD_BRIDGE = _l1StandardBridge;
    }

    /**
     * @notice Send cross-chain message to target on Optimism.
     * @param target Contract on Optimism that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        sendCrossDomainMessage(target, L2_GAS_LIMIT, message);
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
        if (l1Token == address(L1_WETH)) {
            L1_WETH.withdraw(amount);
            L1_STANDARD_BRIDGE.depositETHTo{ value: amount }(to, L2_GAS_LIMIT, "");
        }
        // If the l1Token is USDC, then we send it to the CCTP bridge
        else if (_isCCTPEnabled() && l1Token == address(usdcToken)) {
            _transferUsdc(to, amount);
        } else {
            address bridgeToUse = address(L1_STANDARD_BRIDGE);

            // Check if the L1 token requires a custom bridge. If so, use that bridge over the standard bridge.
            if (l1Token == DAI) bridgeToUse = DAI_OPTIMISM_BRIDGE; // 1. DAI
            if (l1Token == SNX) bridgeToUse = SNX_OPTIMISM_BRIDGE; // 2. SNX

            IERC20(l1Token).forceApprove(bridgeToUse, amount);
            if (l1Token == SNX) SynthetixBridgeToOptimism(bridgeToUse).depositTo(to, amount);
            else IL1StandardBridge(bridgeToUse).depositERC20To(l1Token, l2Token, to, amount, L2_GAS_LIMIT, "");
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
