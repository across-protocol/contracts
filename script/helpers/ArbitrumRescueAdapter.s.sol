// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

// How to run:
// AMOUNT_ETH=2900000000000000000 forge script script/ArbitrumRescueAdapter.s.sol:ArbitrumRescueAdapter -vvvv

contract ArbitrumRescueAdapter is Script, Test {
    function run() external view {
        uint256 amountOfEth = vm.envOr("AMOUNT_ETH", uint256(2.9 ether));

        bytes memory message = abi.encode(amountOfEth);

        console.log("Amount of ETH:", amountOfEth);
        console.log("Message to include in call to relaySpokePoolAdminFunction:");
        console.logBytes(message);
    }
}
