// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

// How to run:
// L1_TOKEN=0x... L2_TOKEN=0x... CHAIN_ID=42161 forge script script/SetupArbitrumSpokePool.s.sol:SetupArbitrumSpokePool -vvvv

interface ISpokePoolWhitelist {
    function whitelistToken(address l2Token, address l1Token) external;
}

interface IHubPoolAdmin {
    function relaySpokePoolAdminFunction(uint256 chainId, bytes memory functionData) external;
    function multicall(bytes[] calldata data) external;
}

contract SetupArbitrumSpokePool is Script, Test {
    function run() external view {
        address l1Token = vm.envAddress("L1_TOKEN");
        address l2Token = vm.envAddress("L2_TOKEN");
        uint256 chainId = vm.envUint("CHAIN_ID");

        // Encode the whitelistToken call on the SpokePool.
        bytes memory whitelistCalldata = abi.encodeWithSelector(
            ISpokePoolWhitelist.whitelistToken.selector,
            l2Token,
            l1Token
        );

        console.log("L1 Token:", l1Token);
        console.log("L2 Token:", l2Token);
        console.log("Chain ID:", chainId);

        console.log("SpokePool.whitelistToken calldata:");
        console.logBytes(whitelistCalldata);

        // Encode the relaySpokePoolAdminFunction call on the HubPool.
        bytes memory relayCalldata = abi.encodeWithSelector(
            IHubPoolAdmin.relaySpokePoolAdminFunction.selector,
            chainId,
            whitelistCalldata
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
