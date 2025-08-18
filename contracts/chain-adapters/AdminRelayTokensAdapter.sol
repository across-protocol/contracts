// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";

/**
 * @dev a custom adapter that allows admin to call `relayTokens` on adapters form HubPool by calling `relayMessage` on this adapter
 */
contract AdminRelayTokensAdapter is AdapterInterface {
    // @dev adapter to delegatecall `relayTokens` on
    address immutable targetAdapter;

    constructor(address _targetAdapter) {
        targetAdapter = _targetAdapter;
    }

    /**
     * @param target address of the spokepool which will be the receiver of tokens for the `relayTokens` call performed by this special adapter
     * @param message abi-encoded arguments: (address l1Token, address l2Token, uint256 amount, address spokePool). These are the required params
     * to perform a `relayTokens` call via an underlying `targetAdapter`
     */
    function relayMessage(address target, bytes calldata message) external payable {
        (address l1Token, address l2Token, uint256 amount, address spokePool) = abi.decode(
            message,
            (address, address, uint256, address)
        );
        require(target == spokePool, "target / spokepool mismatch");

        // We are ok with this low-level call since the adapter address is set by the admin and we've
        // already checked that its not the zero address.
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = targetAdapter.delegatecall(
            abi.encodeWithSignature(
                "relayTokens(address,address,uint256,address)",
                l1Token, // l1Token.
                l2Token, // l2Token.
                uint256(amount), // amount.
                spokePool // to. This should be the spokePool.
            )
        );
        require(success, "delegatecall failed");
    }

    function relayTokens(address, address, uint256, address) external payable {
        revert("not supported");
    }
}
