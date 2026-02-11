// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC7683OrderDepositor } from "../../../../contracts/erc7683/ERC7683OrderDepositor.sol";
import { OnchainCrossChainOrder, ResolvedCrossChainOrder, IOriginSettler } from "../../../../contracts/erc7683/ERC7683.sol";
import { AcrossOrderData, ACROSS_ORDER_DATA_TYPE_HASH } from "../../../../contracts/erc7683/ERC7683Permit2Lib.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";
import { RelayDataHashLib } from "../../../../contracts/libraries/RelayDataHashLib.sol";
import { MockPermit2 } from "../../../../contracts/test/MockPermit2.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

contract ERC7683OrderDepositorTest is Test {
    using AddressToBytes32 for address;

    uint32 private constant START_TIME = 1_700_000_000;

    MockPermit2 internal permit2;
    MintableERC20 internal inputToken;
    ERC7683OrderDepositorHarness internal depositor;

    function setUp() public {
        permit2 = new MockPermit2();
        inputToken = new MintableERC20("Input", "IN", 18);
        depositor = new ERC7683OrderDepositorHarness(permit2, 60);
        depositor.setCurrentTime(START_TIME);
        inputToken.mint(address(this), 1e24);
        inputToken.approve(address(depositor), type(uint256).max);
        vm.warp(START_TIME);
    }

    function testOpenEmitsCorrectOrderIdAndNormalizesOffsetExclusivity() public {
        uint32 exclusivityOffset = 120;
        OnchainCrossChainOrder memory order = _buildOrder(exclusivityOffset);
        ResolvedCrossChainOrder memory resolved = depositor.resolve(order);

        V3SpokePoolInterface.V3RelayData memory relayData = abi.decode(
            resolved.fillInstructions[0].originData,
            (V3SpokePoolInterface.V3RelayData)
        );
        uint32 expectedDeadline = START_TIME + exclusivityOffset;
        assertEq(relayData.exclusivityDeadline, expectedDeadline);
        assertEq(
            resolved.orderId,
            RelayDataHashLib.getRelayDataHash(relayData, _acrossOrderData(exclusivityOffset).destinationChainId)
        );

        vm.expectEmit(true, false, false, true, address(depositor));
        emit IOriginSettler.Open(resolved.orderId, resolved);
        depositor.open(order);

        assertEq(depositor.lastExclusivityDeadline(), expectedDeadline);
    }

    function testOpenKeepsAbsoluteExclusivityTimestamp() public {
        uint32 absoluteDeadline = START_TIME + 100_000;
        OnchainCrossChainOrder memory order = _buildOrder(absoluteDeadline);
        ResolvedCrossChainOrder memory resolved = depositor.resolve(order);

        V3SpokePoolInterface.V3RelayData memory relayData = abi.decode(
            resolved.fillInstructions[0].originData,
            (V3SpokePoolInterface.V3RelayData)
        );
        assertEq(relayData.exclusivityDeadline, absoluteDeadline);

        depositor.open(order);
        assertEq(depositor.lastExclusivityDeadline(), absoluteDeadline);
    }

    function _buildOrder(uint32 exclusivityPeriod) internal view returns (OnchainCrossChainOrder memory order) {
        order.fillDeadline = START_TIME + 1 days;
        order.orderDataType = ACROSS_ORDER_DATA_TYPE_HASH;
        order.orderData = abi.encode(_acrossOrderData(exclusivityPeriod));
    }

    function _acrossOrderData(uint32 exclusivityPeriod) internal view returns (AcrossOrderData memory orderData) {
        orderData.inputToken = address(inputToken);
        orderData.inputAmount = 1e18;
        orderData.outputToken = address(0x2222);
        orderData.outputAmount = 2e18;
        orderData.destinationChainId = 10;
        orderData.recipient = address(0xBEEF).toBytes32();
        orderData.exclusiveRelayer = address(0xCAFE);
        orderData.depositNonce = 7;
        orderData.exclusivityPeriod = exclusivityPeriod;
        orderData.message = "hello";
    }
}

contract ERC7683OrderDepositorHarness is ERC7683OrderDepositor {
    uint32 public currentTime;
    uint32 public lastExclusivityDeadline;

    constructor(
        MockPermit2 _permit2,
        uint256 _quoteBeforeDeadline
    ) ERC7683OrderDepositor(_permit2, _quoteBeforeDeadline) {}

    function setCurrentTime(uint32 _currentTime) external {
        currentTime = _currentTime;
    }

    function getCurrentTime() public view override returns (uint32) {
        return currentTime;
    }

    function computeDepositId(uint256 depositNonce, address) public pure override returns (uint256) {
        return depositNonce + 1_000_000;
    }

    function _callDeposit(
        address,
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        address,
        uint256,
        uint32,
        uint32,
        uint32 exclusivityDeadline,
        bytes memory
    ) internal override {
        lastExclusivityDeadline = exclusivityDeadline;
    }

    function _destinationSettler(uint256) internal view override returns (address) {
        return address(this);
    }
}
