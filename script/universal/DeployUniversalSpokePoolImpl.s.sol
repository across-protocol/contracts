// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { DeployUniversalSpokePool } from "./DeployUniversalSpokePool.s.sol";

/// @title DeployUniversalSpokePoolImpl
/// @notice Redeploys the Universal_SpokePool implementation for an already-deployed proxy
/// (e.g. ahead of an upgradeTo proposed via the HubPool).
/// @dev This is a separate script file so forge records the run under its own broadcast
/// directory (broadcast/DeployUniversalSpokePoolImpl.s.sol/<chainId>/), leaving the original
/// proxy deployment record in broadcast/DeployUniversalSpokePool.s.sol/<chainId>/run-latest.json
/// intact — ExtractDeployedFoundryAddresses.ts derives the SpokePool entry from that record.
/// Mirrors the DeployArbitrumSpokePoolV5/DeployEthereumSpokePoolV5 broadcast convention.
///
/// Example:
///   forge script script/universal/DeployUniversalSpokePoolImpl.s.sol:DeployUniversalSpokePoolImpl \
///     --sig "run(address,uint256)" <SP1_HELIOS> 78000 --rpc-url <RPC_URL> --broadcast -vvvv
contract DeployUniversalSpokePoolImpl is DeployUniversalSpokePool {
    function run(address helios, uint256 oftFeeCap) external override {
        require(
            getDeployedAddress("SpokePool", block.chainid, false) != address(0),
            "No SpokePool proxy deployed on this chain; use DeployUniversalSpokePool for a fresh deployment"
        );
        _deploy(helios, oftFeeCap);
    }
}
