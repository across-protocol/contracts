// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

// Minimal interface for SpokePool upgrade functions
interface ISpokePoolUpgradeable {
    function pauseDeposits(bool pause) external;
    function multicall(bytes[] calldata data) external returns (bytes[] memory results);
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
}

/**
 * @title UpgradeSpokePool
 * @notice Generate calldata to upgrade a SpokePool deployment
 * @dev This script generates the calldata needed to call relaySpokePoolAdminFunction()
 *      on the HubPool from the owner's account.
 *
 * Usage:
 *   forge script script/tasks/UpgradeSpokePool.s.sol:UpgradeSpokePool \
 *     --sig "run(address)" <NEW_IMPLEMENTATION_ADDRESS> \
 *     -vvvv
 */
contract UpgradeSpokePool is Script {
    function run(address implementation) external view {
        require(implementation != address(0), "Implementation address cannot be zero");

        /**
         * We perform this seemingly unnecessary pause/unpause sequence because we want to ensure that the
         * upgrade is successful and the new implementation gets forwarded calls by the proxy contract as expected.
         *
         * Since the upgrade and call happens atomically, the upgrade will revert if the new implementation
         * is not functioning correctly.
         */
        bytes[] memory multicallData = new bytes[](2);
        multicallData[0] = abi.encodeWithSelector(ISpokePoolUpgradeable.pauseDeposits.selector, true);
        multicallData[1] = abi.encodeWithSelector(ISpokePoolUpgradeable.pauseDeposits.selector, false);

        bytes memory data = abi.encodeWithSelector(ISpokePoolUpgradeable.multicall.selector, multicallData);
        bytes memory calldata_ = abi.encodeWithSelector(
            ISpokePoolUpgradeable.upgradeToAndCall.selector,
            implementation,
            data
        );

        console.log("=======================================================");
        console.log("SpokePool Upgrade Calldata Generator");
        console.log("=======================================================");
        console.log("");
        console.log("New Implementation Address:", implementation);
        console.log("");
        console.log("To upgrade a SpokePool on chain <chainId>:");
        console.log("Call relaySpokePoolAdminFunction() on the HubPool with:");
        console.log("  - chainId: <TARGET_CHAIN_ID>");
        console.log("  - calldata:");
        console.logBytes(calldata_);
        console.log("");
        console.log("=======================================================");
    }
}
