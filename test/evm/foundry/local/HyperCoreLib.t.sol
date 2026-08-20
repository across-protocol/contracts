// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { HyperCoreLib } from "../../../../contracts/libraries/HyperCoreLib.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { HyperCoreMockHelper } from "./HyperCoreMockHelper.sol";

// Wrapper contract to expose internal library functions for testing
contract HyperCoreLibWrapper {
    function maximumEVMSendAmountToAmounts(
        uint256 maximumEVMSendAmount,
        int8 decimalDiff
    ) external pure returns (uint256 amountEVMToSend, uint64 amountCoreToReceive) {
        return HyperCoreLib.maximumEVMSendAmountToAmounts(maximumEVMSendAmount, decimalDiff);
    }

    function withdrawable(address account) external view returns (uint64) {
        return HyperCoreLib.withdrawable(account);
    }

    function isHyperEVMChain() external view returns (bool) {
        return HyperCoreLib.isHyperEVMChain();
    }

    function hypeCoreIndex() external view returns (uint32) {
        return HyperCoreLib.hypeCoreIndex();
    }

    function isHype(uint32 erc20CoreIndex) external view returns (bool) {
        return HyperCoreLib.isHype(erc20CoreIndex);
    }

    function toSystemAddress(uint32 erc20CoreIndex) external view returns (address) {
        return HyperCoreLib.toSystemAddress(erc20CoreIndex);
    }

    function perpUsdToCoreWei(uint64 amountPerpUsd) external view returns (uint64) {
        return HyperCoreLib.perpUsdToCoreWei(amountPerpUsd);
    }
}

contract HyperCoreLibTest is HyperCoreMockHelper {
    HyperCoreLibWrapper wrapper;

    function setUp() public {
        wrapper = new HyperCoreLibWrapper();
    }

    // ============ maximumEVMSendAmountToAmounts overflow tests ============

    // With decimalDiff == 0, Core amount equals EVM amount, so exceeding uint64.max reverts
    function testMaximumEVMSendAmountToAmounts_RevertsWhenCoreAmountExceedsUint64Max_ZeroDecimalDiff() public {
        uint256 tooLargeAmount = uint256(type(uint64).max) + 1;

        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 64, tooLargeAmount));
        wrapper.maximumEVMSendAmountToAmounts(tooLargeAmount, 0);
    }

    // With positive decimalDiff, Core amount = EVM / scale, so large EVM can still produce valid Core
    function testMaximumEVMSendAmountToAmounts_WorksWhenEVMExceedsUint64Max_PositiveDecimalDiff() public view {
        // EVM amount exceeds uint64.max but Core amount (after division) fits
        uint256 largeEVMAmount = uint256(type(uint64).max) + 1e6;
        int8 decimalDiff = 6;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(
            largeEVMAmount,
            decimalDiff
        );

        // Core amount should be largeEVMAmount / 1e6, truncated for dust
        assertEq(amountEVMToSend, largeEVMAmount - (largeEVMAmount % 1e6));
        assertEq(amountCoreToReceive, uint64(amountEVMToSend / 1e6));
    }

    // With negative decimalDiff, Core amount = EVM * scale, can overflow even with smaller EVM values
    function testMaximumEVMSendAmountToAmounts_RevertsWhenCoreAmountExceedsUint64Max_NegativeDecimalDiff() public {
        // EVM amount that when scaled up exceeds uint64.max
        // uint64.max ~= 1.8e19, so with scale=1e6, any EVM amount > 1.8e13 will overflow
        uint256 evmAmount = uint256(type(uint64).max / 1e6) + 1; // Just over the limit
        int8 decimalDiff = -6;

        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 64, evmAmount * 1e6));
        wrapper.maximumEVMSendAmountToAmounts(evmAmount, decimalDiff);
    }

    // ============ maximumEVMSendAmountToAmounts boundary tests ============

    function testMaximumEVMSendAmountToAmounts_WorksAtUint64Max_ZeroDecimalDiff() public view {
        uint256 maxAmount = type(uint64).max;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(maxAmount, 0);

        assertEq(amountEVMToSend, maxAmount);
        assertEq(amountCoreToReceive, type(uint64).max);
    }

    function testMaximumEVMSendAmountToAmounts_WorksAtBoundary_NegativeDecimalDiff() public view {
        // Maximum EVM amount that when scaled up equals exactly uint64.max
        uint256 evmAmount = type(uint64).max / 1e6;
        int8 decimalDiff = -6;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(
            evmAmount,
            decimalDiff
        );

        assertEq(amountEVMToSend, evmAmount);
        assertEq(amountCoreToReceive, uint64(evmAmount * 1e6));
    }

    // ============ maximumEVMSendAmountToAmounts decimal conversion tests ============

    function testMaximumEVMSendAmountToAmounts_ZeroDecimalDiff() public view {
        uint256 amount = 1000e6;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(amount, 0);

        assertEq(amountEVMToSend, amount);
        assertEq(amountCoreToReceive, uint64(amount));
    }

    function testMaximumEVMSendAmountToAmounts_PositiveDecimalDiff() public view {
        uint256 amount = 1000e12; // 1000 tokens with 12 decimals on EVM
        int8 decimalDiff = 6; // EVM 12 decimals, Core 6 decimals

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(
            amount,
            decimalDiff
        );

        assertEq(amountEVMToSend, amount);
        assertEq(amountCoreToReceive, uint64(1000e6));
    }

    function testMaximumEVMSendAmountToAmounts_TruncatesDust() public view {
        uint256 amount = 1000e12 + 123456; // Has dust (123456 < 1e6)
        int8 decimalDiff = 6;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(
            amount,
            decimalDiff
        );

        assertEq(amountEVMToSend, 1000e12);
        assertEq(amountCoreToReceive, uint64(1000e6));
    }

    function testMaximumEVMSendAmountToAmounts_NegativeDecimalDiff() public view {
        uint256 amount = 1000;
        int8 decimalDiff = -6;

        (uint256 amountEVMToSend, uint64 amountCoreToReceive) = wrapper.maximumEVMSendAmountToAmounts(
            amount,
            decimalDiff
        );

        assertEq(amountEVMToSend, amount);
        assertEq(amountCoreToReceive, uint64(1000e6));
    }

    // ============ withdrawable ============

    function testWithdrawable_DecodesPrecompileResult() public {
        address account = makeAddr("account");
        vm.mockCall(
            HyperCoreLib.WITHDRAWABLE_PRECOMPILE_ADDRESS,
            abi.encode(account),
            abi.encode(HyperCoreLib.Withdrawable({ withdrawable: 1234e6 }))
        );

        assertEq(wrapper.withdrawable(account), uint64(1234e6));
    }

    function testWithdrawable_RevertsWhenPrecompileFails() public {
        address account = makeAddr("account");
        vm.mockCallRevert(HyperCoreLib.WITHDRAWABLE_PRECOMPILE_ADDRESS, abi.encode(account), "");

        vm.expectRevert(HyperCoreLib.WithdrawablePrecompileCallFailed.selector);
        wrapper.withdrawable(account);
    }

    // ============ chain and HYPE helpers ============

    function testIsHyperEVMChain() public {
        vm.chainId(HyperCoreLib.HYPEREVM_CHAIN_ID);
        assertTrue(wrapper.isHyperEVMChain());

        vm.chainId(HyperCoreLib.HYPEREVM_TESTNET_CHAIN_ID);
        assertTrue(wrapper.isHyperEVMChain());

        vm.chainId(1);
        assertFalse(wrapper.isHyperEVMChain());
    }

    // The HYPE Core index differs between mainnet and testnet, which is why it can't be a constant at call sites
    function testHypeCoreIndex_DiffersOnTestnet() public {
        vm.chainId(HyperCoreLib.HYPEREVM_CHAIN_ID);
        assertEq(wrapper.hypeCoreIndex(), HyperCoreLib.HYPE_CORE_INDEX);

        vm.chainId(HyperCoreLib.HYPEREVM_TESTNET_CHAIN_ID);
        assertEq(wrapper.hypeCoreIndex(), HyperCoreLib.HYPE_CORE_INDEX_TESTNET);
    }

    function testIsHype() public {
        vm.chainId(HyperCoreLib.HYPEREVM_CHAIN_ID);
        assertTrue(wrapper.isHype(HyperCoreLib.HYPE_CORE_INDEX));
        assertFalse(wrapper.isHype(HyperCoreLib.HYPE_CORE_INDEX_TESTNET));
        assertFalse(wrapper.isHype(uint32(HyperCoreLib.USDC_CORE_INDEX)));

        vm.chainId(HyperCoreLib.HYPEREVM_TESTNET_CHAIN_ID);
        assertTrue(wrapper.isHype(HyperCoreLib.HYPE_CORE_INDEX_TESTNET));
        assertFalse(wrapper.isHype(HyperCoreLib.HYPE_CORE_INDEX));
    }

    // ============ toSystemAddress ============

    // HYPE reports no `evmContract`, so its branch has to be taken before the bridgeability check
    function testToSystemAddress_HypeIgnoresAbsentEvmContract() public {
        mockTokenInfoDefault(address(0), "HYPE", 8);

        vm.chainId(HyperCoreLib.HYPEREVM_CHAIN_ID);
        assertEq(wrapper.toSystemAddress(HyperCoreLib.HYPE_CORE_INDEX), HyperCoreLib.HYPE_SYSTEM_ADDRESS);

        vm.chainId(HyperCoreLib.HYPEREVM_TESTNET_CHAIN_ID);
        assertEq(wrapper.toSystemAddress(HyperCoreLib.HYPE_CORE_INDEX_TESTNET), HyperCoreLib.HYPE_SYSTEM_ADDRESS);
    }

    function testToSystemAddress_BridgeableTokenDerivesFromIndex() public {
        uint32 coreIndex = 42;
        mockTokenInfoDefault(makeAddr("erc20"), "TKN", 8);

        vm.chainId(HyperCoreLib.HYPEREVM_CHAIN_ID);
        assertEq(wrapper.toSystemAddress(coreIndex), HyperCoreLib.toAssetBridgeAddress(coreIndex));
    }

    // A token with no linked HyperEVM contract has no EVM side to credit, so the send would strand the funds
    function testToSystemAddress_RevertsWhenTokenNotBridgeable() public {
        uint32 coreIndex = 42;
        mockTokenInfoDefault(address(0), "TKN", 8);

        vm.chainId(HyperCoreLib.HYPEREVM_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreLib.TokenNotBridgeable.selector, coreIndex));
        wrapper.toSystemAddress(coreIndex);
    }

    // ============ perpUsdToCoreWei ============

    // USDC's live config is 8 wei decimals, so a perp USD amount scales up by 1e2
    function testPerpUsdToCoreWei_ScalesUpToUsdcWeiDecimals() public {
        mockTokenInfoDefault(makeAddr("usdc"), "USDC", 8);

        assertEq(wrapper.perpUsdToCoreWei(1234e6), uint64(1234e8));
        assertEq(wrapper.perpUsdToCoreWei(0), uint64(0));
    }

    // The conversion reads USDC's `weiDecimals` rather than assuming a fixed 1e2 factor
    function testPerpUsdToCoreWei_TracksUsdcWeiDecimals() public {
        mockTokenInfoDefault(makeAddr("usdc"), "USDC", HyperCoreLib.PERP_USD_DECIMALS);
        assertEq(wrapper.perpUsdToCoreWei(1234e6), uint64(1234e6));

        // Fewer wei decimals than perp USD rounds down rather than reverting
        mockTokenInfoDefault(makeAddr("usdc"), "USDC", 4);
        assertEq(wrapper.perpUsdToCoreWei(1234.5678e6), uint64(1234.5678e4));
        assertEq(wrapper.perpUsdToCoreWei(1), uint64(0));
    }
}
