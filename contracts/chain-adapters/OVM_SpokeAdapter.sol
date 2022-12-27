// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/SpokeAdapterInterface.sol";
import "../SpokePoolInterface.sol";
import "../interfaces/WETH9.sol";
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";
import "@eth-optimism/contracts/L2/messaging/IL2ERC20Bridge.sol";
import "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

interface OVMSpokePoolInterface is SpokePoolInterface {
    function tokenBridges(address) external view returns (address);
}

// https://github.com/Synthetixio/synthetix/blob/5ca27785fad8237fb0710eac01421cafbbd69647/contracts/SynthetixBridgeToBase.sol#L50
interface SynthetixBridgeToBase {
    function withdrawTo(address to, uint256 amount) external;
}

/**
 * @notice Used on OVM networks to send tokens from SpokePool to HubPool
 */
contract OVM_SpokeAdapter is SpokeAdapterInterface {
    address public immutable spokePool;

    // "l1Gas" parameter used in call to bridge tokens from this contract back to L1 via IL2ERC20Bridge. Currently
    // unused by bridge but included for future compatibility.
    uint32 public immutable l1Gas = 5_000_000;

    // ETH is an ERC20 on OVM.
    address public immutable l2Eth;

    event OptimismTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged, uint256 l1Gas);

    constructor(address _spokePool, address _l2Eth) {
        spokePool = _spokePool;
        l2Eth = _l2Eth;
    }

    /**************************************
     *          INTERNAL FUNCTIONS           *
     **************************************/

    function bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) external override {
        // If the token being bridged is WETH then we need to first unwrap it to ETH and then send ETH over the
        // canonical bridge. On Optimism, this is address 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000.
        address _l2TokenAddressToUse = l2TokenAddress;
        if (_l2TokenAddressToUse == address(SpokePoolInterface(spokePool).wrappedNativeToken())) {
            WETH9(_l2TokenAddressToUse).withdraw(amountToReturn); // Unwrap into ETH.
            _l2TokenAddressToUse = l2Eth; // Set the l2TokenAddress to ETH.
        }
        // Handle custom SNX bridge which doesn't conform to the standard bridge interface.
        if (l2TokenAddress == 0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4)
            SynthetixBridgeToBase(0x136b1EC699c62b0606854056f02dC7Bb80482d63).withdrawTo(
                SpokePoolInterface(spokePool).hubPool(), // _to. Withdraw, over the bridge, to the l1 pool contract.
                amountToReturn // _amount.
            );
        else
            IL2ERC20Bridge(
                OVMSpokePoolInterface(spokePool).tokenBridges(l2TokenAddress) == address(0)
                    ? Lib_PredeployAddresses.L2_STANDARD_BRIDGE
                    : OVMSpokePoolInterface(spokePool).tokenBridges(l2TokenAddress)
            ).withdrawTo(
                    l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
                    SpokePoolInterface(spokePool).hubPool(), // _to. Withdraw, over the bridge, to the l1 pool contract.
                    amountToReturn, // _amount.
                    l1Gas, // _l1Gas. Unused, but included for potential forward compatibility considerations
                    "" // _data. We don't need to send any data for the bridging action.
                );
        emit OptimismTokensBridged(
            _l2TokenAddressToUse,
            SpokePoolInterface(spokePool).hubPool(),
            amountToReturn,
            l1Gas
        );
    }
}
