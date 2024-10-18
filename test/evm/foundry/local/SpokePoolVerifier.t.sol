// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { SpokePoolVerifier } from "../../../../contracts/SpokePoolVerifier.sol";
import { Ethereum_SpokePool } from "../../../../contracts/Ethereum_SpokePool.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";

contract SpokePoolVerifierTest is Test {
    Ethereum_SpokePool ethereumSpokePool;
    SpokePoolVerifier spokePoolVerifier;

    using AddressToBytes32 for address;

    ERC20 mockWETH;
    ERC20 mockERC20;

    address depositor;
    address owner;

    uint256 destinationChainId = 10;
    uint256 mintAmount = 10**22;
    uint256 depositAmount = 5 * (10**18);
    uint32 fillDeadlineBuffer = 7200;

    function setUp() public {
        mockWETH = ERC20(address(new WETH9()));
        mockERC20 = new ERC20("ERC20", "ERC20");

        depositor = vm.addr(1);
        owner = vm.addr(2);

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
        spokePoolVerifier = new SpokePoolVerifier();
        vm.stopPrank();

        deal(depositor, mintAmount);
        deal(address(mockERC20), depositor, mintAmount, true);
        vm.prank(depositor);
        mockERC20.approve(address(ethereumSpokePool), mintAmount);
    }

    function testInvalidMsgValue() public {
        vm.startPrank(depositor);

        // Reverts if inputToken is WETH and msg.value is not equal to inputAmount
        vm.expectRevert(SpokePoolVerifier.InvalidMsgValue.selector);
        spokePoolVerifier.deposit{ value: 0 }(
            ethereumSpokePool, // spokePool
            depositor.toBytes32(), // recipient
            address(mockWETH).toBytes32(), // inputToken
            depositAmount, // inputAmount
            depositAmount, // outputAmount
            destinationChainId, // destinationChainId
            bytes32(0), // exclusiveRelayer
            uint32(block.timestamp), // quoteTimestamp
            uint32(block.timestamp) + fillDeadlineBuffer, // fillDeadline
            0, // exclusivityDeadline
            bytes("") // message
        );

        // Reverts if msg.value matches inputAmount but inputToken is not WETH
        vm.expectRevert(V3SpokePoolInterface.MsgValueDoesNotMatchInputAmount.selector);
        spokePoolVerifier.deposit{ value: depositAmount }(
            ethereumSpokePool, // spokePool
            depositor.toBytes32(), // recipient
            address(mockERC20).toBytes32(), // inputToken
            depositAmount, // inputAmount
            depositAmount, // outputAmount
            destinationChainId, // destinationChainId
            bytes32(0), // exclusiveRelayer
            uint32(block.timestamp), // quoteTimestamp
            uint32(block.timestamp) + fillDeadlineBuffer, // fillDeadline
            0, // exclusivityDeadline
            bytes("") // message
        );

        vm.stopPrank();
    }

    function testInvalidSpokePool() public {
        vm.startPrank(depositor);

        // Reverts if spokePool is not a contract
        vm.expectRevert(SpokePoolVerifier.InvalidSpokePool.selector);
        spokePoolVerifier.deposit{ value: depositAmount }(
            V3SpokePoolInterface(address(0)), // spokePool
            depositor.toBytes32(), // recipient
            address(mockWETH).toBytes32(), // inputToken
            depositAmount, // inputAmount
            depositAmount, // outputAmount
            destinationChainId, // destinationChainId
            bytes32(0), // exclusiveRelayer
            uint32(block.timestamp), // quoteTimestamp
            uint32(block.timestamp) + fillDeadlineBuffer, // fillDeadline
            0, // exclusivityDeadline
            bytes("") // message
        );

        vm.stopPrank();
    }

    function testSuccess() public {
        vm.startPrank(depositor);

        // Deposits WETH
        vm.expectCall(
            address(ethereumSpokePool), // callee
            depositAmount, // value
            abi.encodeWithSignature( // data
                "depositV3(bytes32,bytes32,bytes32,bytes32,uint256,uint256,uint256,bytes32,uint32,uint32,uint256,bytes)",
                abi.encode(
                    depositor.toBytes32(),
                    depositor.toBytes32(),
                    address(mockWETH).toBytes32(),
                    bytes32(0),
                    depositAmount,
                    depositAmount,
                    destinationChainId,
                    bytes32(0),
                    uint32(block.timestamp),
                    uint32(block.timestamp) + fillDeadlineBuffer,
                    0,
                    bytes("")
                )
            )
        );
        spokePoolVerifier.deposit{ value: depositAmount }(
            ethereumSpokePool, // spokePool
            depositor.toBytes32(), // recipient
            address(mockWETH).toBytes32(), // inputToken
            depositAmount, // inputAmount
            depositAmount, // outputAmount
            destinationChainId, // destinationChainId
            bytes32(0), // exclusiveRelayer
            uint32(block.timestamp), // quoteTimestamp
            uint32(block.timestamp) + fillDeadlineBuffer, // fillDeadline
            0, // exclusivityDeadline
            bytes("") // message
        );

        vm.stopPrank();
    }
}
