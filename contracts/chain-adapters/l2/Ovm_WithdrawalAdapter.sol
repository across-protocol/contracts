// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import { WithdrawalAdapter, ITokenMessenger } from "./WithdrawalAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { WETH9Interface } from "../../external/interfaces/WETH9Interface.sol";
import { Lib_PredeployAddresses } from "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";
import { IL2ERC20Bridge } from "../../Ovm_SpokePool.sol";

/**
 * @notice OVM specific bridge adapter. Implements logic to bridge tokens back to mainnet.
 * @custom:security-contact bugs@across.to
 */

interface IOvm_SpokePool {
    // @dev Returns the address of the token bridge for the input l2 token.
    function tokenBridges(address token) external view returns (address);

    // @dev Returns the address of the l1 token set in the spoke pool for the input l2 token.
    function remoteL1Tokens(address token) external view returns (address);

    // @dev Returns the address for the representation of ETH on the l2.
    function l2Eth() external view returns (address);

    // @dev Returns the address of the wrapped native token for the L2.
    function wrappedNativeToken() external view returns (WETH9Interface);

    // @dev Returns the amount of gas the contract allocates for a token withdrawal.
    function l1Gas() external view returns (uint32);
}

/**
 * @title Adapter for interacting with bridges from an OpStack L2 to Ethereum mainnet.
 * @notice This contract is used to share L2-L1 bridging logic with other L2 Across contracts.
 */
contract Ovm_WithdrawalAdapter is WithdrawalAdapter {
    using SafeERC20 for IERC20;

    // Address for the wrapped native token on this chain. For Ovm standard bridges, we need to unwrap
    // this token before initiating the withdrawal. Normally, it is 0x42..006, but there are instances
    // where this address is different.
    WETH9Interface public immutable wrappedNativeToken;
    // Address which represents the native token on L2. For OpStack chains, this is generally 0xDeadDeAdde...aDDeAD0000.
    address public immutable l2Eth;
    // Stores required gas to send tokens back to L1.
    uint32 public immutable l1Gas;
    // Address of the corresponding spoke pool on L2. This is to piggyback off of the spoke pool's supported
    // token routes/defined token bridges.
    IOvm_SpokePool public immutable spokePool;

    /*
     * @notice constructs the withdrawal adapter.
     * @param _l2Usdc address of native USDC on the L2.
     * @param _cctpTokenMessenger address of the CCTP token messenger contract on L2.
     * @param _l2Gateway address of the Optimism ERC20 l2 standard bridge contract.
     */
    constructor(
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        address _l2Gateway,
        IOvm_SpokePool _spokePool
    ) WithdrawalAdapter(_l2Usdc, _cctpTokenMessenger, _l2Gateway) {
        spokePool = _spokePool;
        wrappedNativeToken = spokePool.wrappedNativeToken();
        l2Eth = spokePool.l2Eth();
        l1Gas = spokePool.l1Gas();
    }

    /*
     * @notice Calls CCTP or the Optimism token gateway to withdraw tokens back to the recipient.
     * @param recipient L1 address of the recipient.
     * @param amountToReturn amount of l2Token to send back.
     * @param l2TokenAddress address of the l2Token to send back.
     */
    function withdrawToken(
        address recipient,
        uint256 amountToReturn,
        address l2TokenAddress
    ) public override {
        // If the token being bridged is WETH then we need to first unwrap it to ETH and then send ETH over the
        // canonical bridge. On Optimism, this is address 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000.
        if (l2TokenAddress == address(wrappedNativeToken)) {
            WETH9Interface(l2TokenAddress).withdraw(amountToReturn); // Unwrap into ETH.
            l2TokenAddress = l2Eth; // Set the l2TokenAddress to ETH.
            IL2ERC20Bridge(Lib_PredeployAddresses.L2_STANDARD_BRIDGE).withdrawTo{ value: amountToReturn }(
                l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
                recipient, // _to. Withdraw, over the bridge, to the l1 pool contract.
                amountToReturn, // _amount.
                l1Gas, // _l1Gas. Unused, but included for potential forward compatibility considerations
                "" // _data. We don't need to send any data for the bridging action.
            );
        }
        // If the token is USDC && CCTP bridge is enabled, then bridge USDC via CCTP.
        else if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
            _transferUsdc(recipient, amountToReturn);
        }
        // Note we'll default to withdrawTo instead of bridgeERC20To unless the remoteL1Tokens mapping is set for
        // the l2TokenAddress. withdrawTo should be used to bridge back non-native L2 tokens
        // (i.e. non-native L2 tokens have a canonical L1 token). If we should bridge "native L2" tokens then
        // we'd need to call bridgeERC20To and give allowance to the tokenBridge to spend l2Token from this contract.
        // Therefore for native tokens we should set ensure that remoteL1Tokens is set for the l2TokenAddress.
        else {
            IL2ERC20Bridge tokenBridge = IL2ERC20Bridge(
                spokePool.tokenBridges(l2TokenAddress) == address(0)
                    ? Lib_PredeployAddresses.L2_STANDARD_BRIDGE
                    : spokePool.tokenBridges(l2TokenAddress)
            );
            if (spokePool.remoteL1Tokens(l2TokenAddress) != address(0)) {
                // If there is a mapping for this L2 token to an L1 token, then use the L1 token address and
                // call bridgeERC20To.
                IERC20(l2TokenAddress).safeIncreaseAllowance(address(tokenBridge), amountToReturn);
                address remoteL1Token = spokePool.remoteL1Tokens(l2TokenAddress);
                tokenBridge.bridgeERC20To(
                    l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
                    remoteL1Token, // Remote token to be received on L1 side. If the
                    // remoteL1Token on the other chain does not recognize the local token as the correct
                    // pair token, the ERC20 bridge will fail and the tokens will be returned to sender on
                    // this chain.
                    recipient, // _to
                    amountToReturn, // _amount
                    l1Gas, // _l1Gas
                    "" // _data
                );
            } else {
                tokenBridge.withdrawTo(
                    l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
                    recipient, // _to. Withdraw, over the bridge, to the l1 pool contract.
                    amountToReturn, // _amount.
                    l1Gas, // _l1Gas. Unused, but included for potential forward compatibility considerations
                    "" // _data. We don't need to send any data for the bridging action.
                );
            }
        }
    }
}
