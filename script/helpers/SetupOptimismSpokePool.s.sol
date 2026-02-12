// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

// How to run:
// L2_TOKEN=0x... BRIDGE=0x... CHAIN_ID=10 forge script script/SetupOptimismSpokePool.s.sol:SetupOptimismSpokePool -vvvv

interface ISpokePoolTokenBridge {
    function setTokenBridge(address l2Token, address tokenBridge) external;
}

interface IHubPoolAdmin {
    function relaySpokePoolAdminFunction(uint256 chainId, bytes memory functionData) external;
    function multicall(bytes[] calldata data) external;
}

contract SetupOptimismSpokePool is Script, Test {
    function run() external view {
        address l2Token = vm.envAddress("L2_TOKEN");
        address bridge = vm.envAddress("BRIDGE");
        uint256 chainId = vm.envUint("CHAIN_ID");

        // Encode the setTokenBridge call on the SpokePool.
        bytes memory setTokenBridgeCalldata = abi.encodeWithSelector(
            ISpokePoolTokenBridge.setTokenBridge.selector,
            l2Token,
            bridge
        );

        console.log("L2 Token:", l2Token);
        console.log("Bridge:", bridge);
        console.log("Chain ID:", chainId);

        console.log("SpokePool.setTokenBridge calldata:");
        console.logBytes(setTokenBridgeCalldata);

        // Encode the relaySpokePoolAdminFunction call on the HubPool.
        bytes memory relayCalldata = abi.encodeWithSelector(
            IHubPoolAdmin.relaySpokePoolAdminFunction.selector,
            chainId,
            setTokenBridgeCalldata
        );

        console.log("HubPool.relaySpokePoolAdminFunction calldata:");
        console.logBytes(relayCalldata);

        // Wrap in a multicall for convenience.
        bytes[] memory multicallData = new bytes[](1);
        multicallData[0] = relayCalldata;
        bytes memory multicallCalldata = abi.encodeWithSelector(IHubPoolAdmin.multicall.selector, multicallData);

        console.log("HubPool.multicall calldata:");
        console.logBytes(multicallCalldata);
    }
}
