// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { SpokePoolPeriphery } from "../../../../contracts/periphery/SpokePoolPeriphery.sol";
import { Tron_SpokePoolPeriphery } from "../../../../contracts/periphery/Tron_SpokePoolPeriphery.sol";
import { SpokePoolPeripheryInterface } from "../../../../contracts/interfaces/SpokePoolPeripheryInterface.sol";
import { TronTransferLib } from "../../../../contracts/libraries/TronTransferLib.sol";
import { Ethereum_SpokePool } from "../../../../contracts/spoke-pools/Ethereum_SpokePool.sol";
import { IPermit2 } from "../../../../contracts/external/interfaces/IPermit2.sol";
import { MockPermit2 } from "../../../../contracts/test/MockPermit2.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";
import { MockTronUSDT } from "../../../../contracts/test/MockTronUSDT.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { Multicall3 } from "../../../../contracts/external/Multicall3.sol";

/// @dev Minimal exchange: the SwapProxy pre-funds it with the input token (TransferType.Transfer),
///      so the swap only pays out the output token. The `transfer` return value is deliberately
///      ignored so Tron USDT's false-on-success return does not revert the swap itself.
contract MockTronDex {
    function swap(IERC20 tokenOut, uint256 amountOut) external {
        tokenOut.transfer(msg.sender, amountOut);
    }
}

contract Tron_SpokePoolPeripheryTest is Test {
    using AddressToBytes32 for address;

    Tron_SpokePoolPeriphery periphery;
    Ethereum_SpokePool spokePool;
    MockTronDex dex;
    IPermit2 permit2;
    WETH9 weth;
    MockTronUSDT usdt;
    MintableERC20 vanilla;
    Multicall3 multicall3;

    address owner = makeAddr("owner");
    address depositor = makeAddr("depositor");

    uint256 constant SWAP_AMOUNT = 100e6;
    uint256 constant DEPOSIT_AMOUNT = 95e6;
    uint32 constant FILL_DEADLINE_BUFFER = 7200;

    function setUp() public {
        weth = new WETH9();
        usdt = new MockTronUSDT();
        vanilla = new MintableERC20("Vanilla", "VAN", 6);
        permit2 = IPermit2(new MockPermit2());
        dex = new MockTronDex();
        multicall3 = new Multicall3();
        periphery = new Tron_SpokePoolPeriphery(permit2, address(multicall3));

        Ethereum_SpokePool impl = new Ethereum_SpokePool(
            address(weth),
            FILL_DEADLINE_BUFFER,
            FILL_DEADLINE_BUFFER,
            address(0)
        );
        spokePool = Ethereum_SpokePool(
            payable(new ERC1967Proxy(address(impl), abi.encodeCall(Ethereum_SpokePool.initialize, (0, owner))))
        );

        vm.startPrank(depositor);
        usdt.approve(address(periphery), type(uint256).max);
        vanilla.approve(address(periphery), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev USDT is the swap token: exercises the periphery's `_safeTransfer` (periphery -> swap proxy)
    ///      and the Tron_SwapProxy's `_safeTransfer` (proxy -> exchange), both of which return false on
    ///      success and would revert on the mainline contracts.
    function test_SwapAndBridge_TronUSDTSwapToken() public {
        usdt.mint(depositor, SWAP_AMOUNT);
        vanilla.mint(address(dex), DEPOSIT_AMOUNT);

        vm.prank(depositor);
        periphery.swapAndBridge(_swapData(address(usdt), address(vanilla), DEPOSIT_AMOUNT));

        assertEq(usdt.balanceOf(address(dex)), SWAP_AMOUNT, "Exchange should receive USDT swap input");
        assertEq(vanilla.balanceOf(address(spokePool)), DEPOSIT_AMOUNT, "SpokePool should receive deposit");
    }

    /// @dev USDT is the Across input token: exercises the Tron_SwapProxy's output-return `_safeTransfer`
    ///      (proxy -> periphery); the SpokePool then pulls USDT via safeTransferFrom, which is standard
    ///      on Tron USDT.
    function test_SwapAndBridge_TronUSDTInputToken() public {
        vanilla.mint(depositor, SWAP_AMOUNT);
        usdt.mint(address(dex), DEPOSIT_AMOUNT);

        vm.prank(depositor);
        periphery.swapAndBridge(_swapData(address(vanilla), address(usdt), DEPOSIT_AMOUNT));

        assertEq(usdt.balanceOf(address(spokePool)), DEPOSIT_AMOUNT, "SpokePool should receive USDT deposit");
    }

    function test_SwapAndBridge_RevertsOnGenuineTransferFailure() public {
        usdt.mint(depositor, SWAP_AMOUNT);
        vanilla.mint(address(dex), DEPOSIT_AMOUNT);
        // Blacklisting the exchange makes the proxy -> exchange USDT transfer genuinely revert.
        usdt.setBlacklisted(address(dex), true);

        vm.prank(depositor);
        vm.expectRevert(TronTransferLib.TronTransferCallReverted.selector);
        periphery.swapAndBridge(_swapData(address(usdt), address(vanilla), DEPOSIT_AMOUNT));
    }

    /// @dev Baseline showing why the variant exists: the mainline periphery's default `_safeTransfer`
    ///      treats Tron USDT's false return as failure.
    function test_BasePeriphery_RevertsOnTronUSDT() public {
        SpokePoolPeriphery basePeriphery = new SpokePoolPeriphery(permit2, address(multicall3));
        usdt.mint(depositor, SWAP_AMOUNT);
        vanilla.mint(address(dex), DEPOSIT_AMOUNT);
        SpokePoolPeripheryInterface.SwapAndDepositData memory data = _swapData(
            address(usdt),
            address(vanilla),
            DEPOSIT_AMOUNT
        );

        vm.startPrank(depositor);
        usdt.approve(address(basePeriphery), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdt)));
        basePeriphery.swapAndBridge(data);
        vm.stopPrank();
    }

    function _swapData(
        address swapToken,
        address inputToken,
        uint256 amountOut
    ) internal view returns (SpokePoolPeripheryInterface.SwapAndDepositData memory) {
        return
            SpokePoolPeripheryInterface.SwapAndDepositData({
                submissionFees: SpokePoolPeripheryInterface.Fees({ amount: 0, recipient: address(0) }),
                depositData: SpokePoolPeripheryInterface.BaseDepositData({
                    inputToken: inputToken,
                    outputToken: inputToken.toBytes32(),
                    outputAmount: amountOut,
                    depositor: depositor,
                    recipient: depositor.toBytes32(),
                    destinationChainId: 10,
                    exclusiveRelayer: bytes32(0),
                    quoteTimestamp: uint32(block.timestamp),
                    fillDeadline: uint32(block.timestamp) + FILL_DEADLINE_BUFFER,
                    exclusivityParameter: 0,
                    message: new bytes(0)
                }),
                swapToken: swapToken,
                exchange: address(dex),
                transferType: SpokePoolPeripheryInterface.TransferType.Transfer,
                swapTokenAmount: SWAP_AMOUNT,
                minExpectedInputTokenAmount: amountOut,
                routerCalldata: abi.encodeWithSelector(MockTronDex.swap.selector, IERC20(inputToken), amountOut),
                enableProportionalAdjustment: false,
                spokePool: address(spokePool),
                nonce: 0
            });
    }
}
