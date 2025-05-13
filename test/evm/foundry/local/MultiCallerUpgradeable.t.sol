// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import "forge-std/console.sol";

import { SpokePool } from "../../../../contracts/SpokePool.sol";
import { Ethereum_SpokePool } from "../../../../contracts/Ethereum_SpokePool.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";

// This test does not require a mainnet fork (since it is testing contracts before deployment).
contract MultiCallerUpgradeableTest is Test {
    Ethereum_SpokePool ethereumSpokePool;

    using AddressToBytes32 for address;

    ERC20 mockWETH;
    ERC20 mockL2WETH;

    address rando1;
    address rando2;
    address relayer;

    SpokePool.V3RelayData mockRelayData;

    function setUp() public {
        mockWETH = new ERC20("Wrapped Ether", "WETH");
        mockL2WETH = new ERC20("L2 Wrapped Ether", "L2WETH");

        ethereumSpokePool = new Ethereum_SpokePool(address(mockWETH), 0, 0);

        rando1 = vm.addr(1);
        rando2 = vm.addr(2);
        relayer = vm.addr(3);

        deal(address(mockL2WETH), relayer, 10**22, true);

        vm.prank(relayer);
        IERC20(address(mockL2WETH)).approve(address(ethereumSpokePool), 2**256 - 1);

        // Create Dummy Relay Data
        uint256 depositAmount = 5 * (10**18);
        uint256 mockRepaymentChainId = 1;
        uint32 fillDeadline = uint32(ethereumSpokePool.getCurrentTime()) + 1000;

        mockRelayData.depositor = rando1.toBytes32();
        mockRelayData.recipient = rando2.toBytes32();
        mockRelayData.exclusiveRelayer = relayer.toBytes32();
        mockRelayData.inputToken = address(mockWETH).toBytes32();
        mockRelayData.outputToken = address(mockL2WETH).toBytes32();
        mockRelayData.inputAmount = depositAmount;
        mockRelayData.outputAmount = depositAmount;
        mockRelayData.originChainId = mockRepaymentChainId;
        mockRelayData.depositId = 0;
        mockRelayData.fillDeadline = fillDeadline;
        mockRelayData.exclusivityDeadline = fillDeadline - 500;
        mockRelayData.message = bytes("");
    }

    function testTryMulticallOnlySuccesses(uint8 numberOfFunctions) public {
        numberOfFunctions = uint8(bound(numberOfFunctions, 1, 255));

        bytes[] memory calls = new bytes[](numberOfFunctions);
        for (uint8 i = 0; i < numberOfFunctions; ++i) {
            mockRelayData.depositId = i;

            calls[i] = abi.encodeWithSelector(SpokePool.fillV3Relay.selector, mockRelayData, 1);
        }

        vm.prank(relayer);
        SpokePool.Result[] memory results = ethereumSpokePool.tryMulticall(calls);

        for (uint8 i = 0; i < numberOfFunctions; ++i) {
            assert(results[i].success);
        }
    }

    function testTryMulticallWithFailures(uint8 numberOfFunctions, uint256 randomSeed) public {
        numberOfFunctions = uint8(bound(numberOfFunctions, 1, 255));

        bytes[] memory calls = new bytes[](numberOfFunctions);

        for (uint8 i = 0; i < numberOfFunctions; ++i) {
            uint256 mask = 1 << i;
            if (randomSeed & mask == mask) {
                mockRelayData.depositId = i;
                calls[i] = abi.encodeWithSelector(SpokePool.fillV3Relay.selector, mockRelayData, 1);
            } else {
                // Relayer is not an admin. Delegatecall will fail.
                calls[i] = abi.encodeWithSelector(SpokePool.pauseDeposits.selector, true);
            }
        }

        vm.prank(relayer);
        SpokePool.Result[] memory results = ethereumSpokePool.tryMulticall(calls);

        for (uint8 i = 0; i < numberOfFunctions; ++i) {
            uint256 mask = 1 << i;
            if (randomSeed & mask == mask) {
                assert(results[i].success);
            } else {
                assert(!results[i].success);
                assertEq(
                    "", // Error messages are stripped.
                    results[i].returnData
                );
            }
        }
    }
}
