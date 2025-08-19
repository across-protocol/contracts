// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AdapterInterface } from "./interfaces/AdapterInterface.sol";

/**
 * @dev A custom adapter that allows admin to delegatecall `relayTokens` on other adapters by calling `relaySpokePoolAdminFunction` on the HubPool
 */
contract AdminRelayTokensAdapter is AdapterInterface {
    // @dev Underlying adapter whose `relayTokens` logic will be executed via delegatecall. Must be trusted
    address public immutable UNDERLYING_ADAPTER;

    constructor(address underlyingAdapter) {
        UNDERLYING_ADAPTER = underlyingAdapter;
    }

    /**
     * @param target Receiver of tokens on the destination chain. SpokePool address passed in by the HubPool
     * @param message Abi-encoded arguments params for the `relayTokens` function call: (address l1Token,
     * address l2Token, uint256 amount, address spokePool)
     */
    function relayMessage(address target, bytes calldata message) external payable {
        // This adapter is not intended to accept any value as a part of `relayMessage`. It's intended usecase is to be
        // `deletagecall`ed into, and delegatecall does not allow for attaching the `value`
        require(msg.value == 0, "value transfer not supported");

        (address l1Token, address l2Token, uint256 amount, address spokePool) = abi.decode(
            message,
            (address, address, uint256, address)
        );
        require(target == spokePool, "target / spokepool mismatch");

        // We are ok with this low-level call since the adapter address is set by the admin and we've
        // already checked that its not the zero address.
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = UNDERLYING_ADAPTER.delegatecall(
            abi.encodeWithSelector(
                AdapterInterface.relayTokens.selector,
                l1Token, // l1Token.
                l2Token, // l2Token.
                amount, // amount.
                spokePool // to. This should be the spokePool.
            )
        );
        require(success, "delegatecall failed");
    }

    function relayTokens(address, address, uint256, address) external payable {
        revert("not supported");
    }
}
