// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HubPoolStore } from "../../../../contracts/chain-adapters/Universal_Adapter.sol";

contract HubPoolStoreTest is Test {
    HubPoolStore store;

    address hubPool;

    bytes message = abi.encode("message");
    address target = makeAddr("target");

    function setUp() public {
        hubPool = vm.addr(1);
        store = new HubPoolStore(hubPool);
    }

    function testStoreRelayMessageCalldata() public {
        // Only hub pool can call this function.
        vm.expectRevert();
        store.storeRelayMessageCalldata(target, message, true);

        vm.prank(hubPool);
        store.storeRelayMessageCalldata(target, message, true);
        assertEq(store.relayMessageCallData(0), keccak256(abi.encode(target, message)));
    }
}
