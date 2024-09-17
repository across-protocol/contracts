// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

// @dev Use local modified CrossDomainEnabled contract instead of one exported by eth-optimism because we need
// this contract's state variables to be `immutable` because of the delegateCall call.
import "./CrossDomainEnabled.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../libraries/CircleCCTPAdapter.sol";
import "../external/interfaces/CCTPInterfaces.sol";

interface IL1ERC20Bridge {
    /// @notice Sends ERC20 tokens to a receiver's address on the other chain. Note that if the
    ///         ERC20 token on the other chain does not recognize the local token as the correct
    ///         pair token, the ERC20 bridge will fail and the tokens will be returned to sender on
    ///         this chain.
    /// @param _localToken  Address of the ERC20 on this chain.
    /// @param _remoteToken Address of the corresponding token on the remote chain.
    /// @param _to          Address of the receiver.
    /// @param _amount      Amount of local tokens to deposit.
    /// @param _minGasLimit Minimum amount of gas that the bridge can be relayed with.
    /// @param _extraData   Extra data to be sent with the transaction. Note that the recipient will
    ///                     not be triggered with this data, but it will be emitted and can be used
    ///                     to identify the transaction.
    function bridgeERC20To(
        address _localToken,
        address _remoteToken,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external;
}

/**
 * @notice Contract containing logic to send messages from L1 to Blast. This is a modified version of the Optimism adapter
 * that excludes the custom bridging logic. It differs from the Base Adapter in that it uses a special
 * Blast contract to bridge WETH and DAI, which are yielding rebasing tokens on L2, WETH and USDB.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Blast_Adapter is CrossDomainEnabled, AdapterInterface, CircleCCTPAdapter {
    using SafeERC20 for IERC20;
    uint32 public immutable L2_GAS_LIMIT; // 200,000 is a reasonable default.

    WETH9Interface public immutable L1_WETH;

    IL1StandardBridge public immutable L1_STANDARD_BRIDGE; // 0x697402166Fbf2F22E970df8a6486Ef171dbfc524

    // Bridge used to get yielding version of ERC20's on L2.
    IL1ERC20Bridge public immutable L1_BLAST_BRIDGE; // 0x3a05E5d33d7Ab3864D53aaEc93c8301C1Fa49115 on mainnet.
    address public immutable L1_DAI; // 0x6B175474E89094C44Da98b954EedeAC495271d0F on mainnet.

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _crossDomainMessenger XDomainMessenger Blast system contract.
     * @param _l1StandardBridge Standard bridge contract.
     * @param _l1Usdc USDC address on L1.
     */
    constructor(
        WETH9Interface _l1Weth,
        address _crossDomainMessenger,
        IL1StandardBridge _l1StandardBridge,
        IERC20 _l1Usdc,
        IL1ERC20Bridge l1BlastBridge,
        address l1Dai,
        uint32 l2GasLimit
    )
        CrossDomainEnabled(_crossDomainMessenger)
        // Hardcode cctp messenger to 0x0 to disable CCTP bridging.
        CircleCCTPAdapter(_l1Usdc, ITokenMessenger(address(0)), CircleDomainIds.UNINITIALIZED)
    {
        L1_WETH = _l1Weth;
        L1_STANDARD_BRIDGE = _l1StandardBridge;
        L1_BLAST_BRIDGE = l1BlastBridge;
        L1_DAI = l1Dai;
        L2_GAS_LIMIT = l2GasLimit;
    }

    /**
     * @notice Send cross-chain message to target on Blast.
     * @param target Contract on Blast that will receive message.
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

        // If the l1Token is weth then unwrap it to ETH then send the ETH to the standard bridge.
        if (l1Token == address(L1_WETH)) {
            L1_WETH.withdraw(amount);
            // @dev: we can use the standard or the blast bridge to deposit ETH here:
            L1_STANDARD_BRIDGE.depositETHTo{ value: amount }(to, L2_GAS_LIMIT, "");
        }
        // Check if this token is DAI, then use the L1 Blast Bridge
        else if (l1Token == L1_DAI) {
            IERC20(l1Token).safeIncreaseAllowance(address(L1_BLAST_BRIDGE), amount);
            L1_BLAST_BRIDGE.bridgeERC20To(l1Token, l2Token, to, amount, L2_GAS_LIMIT, "");
        } else {
            IL1StandardBridge _l1StandardBridge = L1_STANDARD_BRIDGE;

            IERC20(l1Token).safeIncreaseAllowance(address(_l1StandardBridge), amount);
            _l1StandardBridge.depositERC20To(l1Token, l2Token, to, amount, L2_GAS_LIMIT, "");
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
