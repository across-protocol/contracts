// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/SpokeAdapterInterface.sol";
import "../SpokePoolInterface.sol";

interface ArbitrumSpokePoolInterface is SpokePoolInterface {
    function whitelistedTokens(address) external view returns (address);
}

interface StandardBridgeLike {
    function outboundTransfer(
        address _l1Token,
        address _to,
        uint256 _amount,
        bytes calldata _data
    ) external payable returns (bytes memory);
}

/**
 * @notice Used on Arbitrum to send tokens from SpokePool to HubPool
 */
contract Arbitrum_SpokeAdapter is SpokeAdapterInterface {
    // Address of spoke pool that delegatecalls into this adapter.
    address public immutable spokePool;

    // Address of the Arbitrum L2 token gateway to send funds to L1.
    address public immutable l2GatewayRouter;

    event ArbitrumTokensBridged(address indexed l1Token, address target, uint256 numberOfTokensBridged);

    constructor(address _spokePool, address _l2GatewayRouter) {
        spokePool = _spokePool;
        l2GatewayRouter = _l2GatewayRouter;
    }

    function bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) external override {
        // Check that the Ethereum counterpart of the L2 token is stored on this contract.
        address ethereumTokenToBridge = ArbitrumSpokePoolInterface(spokePool).whitelistedTokens(l2TokenAddress);
        require(ethereumTokenToBridge != address(0), "Uninitialized mainnet token");
        StandardBridgeLike(l2GatewayRouter).outboundTransfer(
            ethereumTokenToBridge, // _l1Token. Address of the L1 token to bridge over.
            SpokePoolInterface(spokePool).hubPool(), // _to. Withdraw, over the bridge, to the l1 hub pool contract.
            amountToReturn, // _amount.
            "" // _data. We don't need to send any data for the bridging action.
        );
        emit ArbitrumTokensBridged(address(0), SpokePoolInterface(spokePool).hubPool(), amountToReturn);
    }
}
