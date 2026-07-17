// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { MulticallHandler } from "../../../../contracts/handlers/MulticallHandler.sol";
import { TronMulticallHandler } from "../../../../contracts/handlers/TronMulticallHandler.sol";
import { TronTransferLib } from "../../../../contracts/libraries/TronTransferLib.sol";
import { MockTronUSDT } from "../../../../contracts/test/MockTronUSDT.sol";

contract TronMulticallHandlerTest is Test {
    TronMulticallHandler handler;
    MockTronUSDT usdt;

    address fallbackRecipient = makeAddr("fallbackRecipient");

    function setUp() public {
        handler = new TronMulticallHandler();
        usdt = new MockTronUSDT();
    }

    function testFallbackDrain_TronUSDT_SucceedsWhenTransferReturnsFalse() public {
        uint256 amount = 100e6;
        usdt.mint(address(handler), amount);

        MulticallHandler.Instructions memory instructions = MulticallHandler.Instructions({
            calls: new MulticallHandler.Call[](0),
            fallbackRecipient: fallbackRecipient
        });

        handler.handleV3AcrossMessage(address(usdt), amount, address(0), abi.encode(instructions));

        assertEq(usdt.balanceOf(fallbackRecipient), amount, "recipient should receive USDT");
        assertEq(usdt.balanceOf(address(handler)), 0, "handler should be drained");
    }

    function testFallbackDrain_TronUSDT_RevertsOnActualTransferFailure() public {
        uint256 amount = 100e6;
        usdt.mint(address(handler), amount);
        usdt.setBlacklisted(fallbackRecipient, true);

        MulticallHandler.Instructions memory instructions = MulticallHandler.Instructions({
            calls: new MulticallHandler.Call[](0),
            fallbackRecipient: fallbackRecipient
        });

        vm.expectRevert(TronTransferLib.TronTransferCallReverted.selector);
        handler.handleV3AcrossMessage(address(usdt), amount, address(0), abi.encode(instructions));
    }
}
