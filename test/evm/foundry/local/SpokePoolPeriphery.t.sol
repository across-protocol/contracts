// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { SpokePoolVerifier } from "../../../../contracts/SpokePoolVerifier.sol";
import { SpokePoolV3Periphery } from "../../../../contracts/SpokeV3PoolPeriphery.sol";
import { Ethereum_SpokePool } from "../../../../contracts/Ethereum_SpokePool.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Exchange {
    function swap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) external {
        require(tokenIn.transferFrom(msg.sender, address(this), amountIn));
        require(tokenOut.transfer(msg.sender, amountOutMin));
    }

    function stealYourMoney(IERC20 tokenIn, uint256 amount) external {
        require(tokenIn.transferFrom(msg.sender, address(this), amount));
    }
}

contract SpokePoolPeripheryTest is Test {
    Ethereum_SpokePool ethereumSpokePool;
    SpokePoolV3Periphery spokePoolPeriphery;
    Exchange dex;
    Exchange cex;

    WETH9Interface mockWETH;
    ERC20 mockERC20;

    address depositor;
    address owner;
    address recipient;

    uint256 destinationChainId = 10;
    uint256 mintAmount = 10**22;
    uint256 depositAmount = 5 * (10**18);
    uint32 fillDeadlineBuffer = 7200;

    SpokePoolV3Periphery.WhitelistedExchanges[] exchanges;

    function setUp() public {
        spokePoolPeriphery = new SpokePoolV3Periphery();
        dex = new Exchange();
        cex = new Exchange();

        mockWETH = WETH9Interface(address(new WETH9()));
        mockERC20 = new ERC20("ERC20", "ERC20");

        depositor = vm.addr(1);
        owner = vm.addr(2);
        recipient = vm.addr(3);

        vm.startPrank(owner);
        Ethereum_SpokePool implementation = new Ethereum_SpokePool(
            address(mockWETH),
            fillDeadlineBuffer,
            fillDeadlineBuffer
        );
        address proxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeCall(Ethereum_SpokePool.initialize, (0, owner)))
        );
        ethereumSpokePool = Ethereum_SpokePool(payable(proxy));
        ethereumSpokePool.setEnableRoute(address(mockWETH), destinationChainId, true);
        ethereumSpokePool.setEnableRoute(address(mockERC20), destinationChainId, true);
        vm.stopPrank();

        deal(depositor, mintAmount);
        deal(address(mockERC20), depositor, mintAmount, true);
        deal(address(mockERC20), address(dex), depositAmount, true);
        // deal(address(mockWETH), address(dex), depositAmount, true);
        vm.startPrank(depositor);
        mockWETH.deposit{ value: mintAmount }();
        mockERC20.approve(address(spokePoolPeriphery), mintAmount);
        IERC20(address(mockWETH)).approve(address(spokePoolPeriphery), mintAmount);
        vm.stopPrank();

        exchanges = new SpokePoolV3Periphery.WhitelistedExchanges[](2);
        exchanges[0] = SpokePoolV3Periphery.WhitelistedExchanges({
            exchange: address(dex),
            allowedSelectors: new bytes4[](1)
        });
        exchanges[0].allowedSelectors[0] = dex.swap.selector;
        exchanges[1] = SpokePoolV3Periphery.WhitelistedExchanges({
            exchange: address(cex),
            allowedSelectors: new bytes4[](1)
        });
        exchanges[1].allowedSelectors[0] = cex.swap.selector;
    }

    function testInitialize() public {
        spokePoolPeriphery.initialize(V3SpokePoolInterface(ethereumSpokePool), mockWETH, exchanges);

        assertEq(address(spokePoolPeriphery.spokePool()), address(ethereumSpokePool));
        assertEq(address(spokePoolPeriphery.wrappedNativeToken()), address(mockWETH));
        assertTrue(spokePoolPeriphery.allowedSelectors(address(dex), dex.swap.selector));
        assertTrue(spokePoolPeriphery.allowedSelectors(address(cex), cex.swap.selector));
        assertFalse(spokePoolPeriphery.allowedSelectors(address(dex), dex.stealYourMoney.selector));

        vm.expectRevert(SpokePoolV3Periphery.ContractInitialized.selector);
        spokePoolPeriphery.initialize(V3SpokePoolInterface(ethereumSpokePool), mockWETH, exchanges);
    }

    function testSwapAndBridge() public {
        spokePoolPeriphery.initialize(V3SpokePoolInterface(ethereumSpokePool), mockWETH, exchanges);

        // Should emit expected deposit event
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockERC20),
            address(0),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridge(
            IERC20(address(mockWETH)), // swapToken
            IERC20(mockERC20), // acrossInputToken
            address(dex),
            abi.encodeWithSelector(
                dex.swap.selector,
                IERC20(address(mockWETH)),
                IERC20(mockERC20),
                mintAmount,
                depositAmount
            ),
            mintAmount, // swapTokenAmount
            depositAmount, // minExpectedInputTokenAmount
            SpokePoolV3Periphery.DepositData({
                outputToken: address(0),
                outputAmount: depositAmount,
                depositor: depositor,
                recipient: depositor,
                destinationChainId: destinationChainId,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp) + fillDeadlineBuffer,
                exclusivityParameter: 0,
                message: new bytes(0)
            })
        );

        vm.stopPrank();
    }

    function testSwapAndBridgeWithValue() public {
        deal(depositor, mintAmount);

        spokePoolPeriphery.initialize(V3SpokePoolInterface(ethereumSpokePool), mockWETH, exchanges);

        // Should emit expected deposit event
        vm.startPrank(depositor);

        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockERC20),
            address(0),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridge{ value: mintAmount }(
            IERC20(address(mockWETH)), // swapToken
            IERC20(mockERC20), // acrossInputToken
            address(dex),
            abi.encodeWithSelector(
                dex.swap.selector,
                IERC20(address(mockWETH)),
                IERC20(mockERC20),
                mintAmount,
                depositAmount
            ),
            mintAmount, // swapTokenAmount
            depositAmount, // minExpectedInputTokenAmount
            SpokePoolV3Periphery.DepositData({
                outputToken: address(0),
                outputAmount: depositAmount,
                depositor: depositor,
                recipient: depositor,
                destinationChainId: destinationChainId,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp) + fillDeadlineBuffer,
                exclusivityParameter: 0,
                message: new bytes(0)
            })
        );

        vm.stopPrank();
    }

    function testDepositWithValue() public {
        spokePoolPeriphery.initialize(
            V3SpokePoolInterface(ethereumSpokePool),
            mockWETH,
            new SpokePoolV3Periphery.WhitelistedExchanges[](0)
        );
        deal(depositor, mintAmount);

        // Should emit expected deposit event
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockWETH),
            address(0),
            mintAmount,
            mintAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.deposit{ value: mintAmount }(
            depositor, // recipient
            address(mockWETH), // inputToken
            mintAmount,
            mintAmount,
            destinationChainId,
            address(0), // exclusiveRelayer
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0,
            new bytes(0)
        );

        vm.stopPrank();
    }
}
