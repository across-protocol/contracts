// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import { Tron_SpokePool } from "../../../../contracts/spoke-pools/Tron_SpokePool.sol";
import { Universal_SpokePool } from "../../../../contracts/spoke-pools/Universal_SpokePool.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../../../../contracts/libraries/AddressConverters.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";

import { MockTronUSDT } from "../../../../contracts/test/MockTronUSDT.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/// @dev Test harness exposing internal hooks of Tron_SpokePool.
contract Testable_Tron_SpokePool is Tron_SpokePool {
    constructor(
        uint256 _adminUpdateBufferSeconds,
        address _helios,
        address _hubPoolStore,
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _oftDstEid,
        uint256 _oftFeeCap
    )
        Tron_SpokePool(
            _adminUpdateBufferSeconds,
            _helios,
            _hubPoolStore,
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            _l2Usdc,
            _cctpTokenMessenger,
            _oftDstEid,
            _oftFeeCap
        )
    {} // solhint-disable-line no-empty-blocks

    function distributeRelayerRefundsExternal(
        uint256 _chainId,
        uint256 amountToReturn,
        uint256[] memory refundAmounts,
        uint32 leafId,
        address l2TokenAddress,
        address[] memory refundAddresses
    ) external {
        _distributeRelayerRefunds(_chainId, amountToReturn, refundAmounts, leafId, l2TokenAddress, refundAddresses);
    }

    function fillRelayV3External(
        V3RelayExecutionParams memory relayExecution,
        bytes32 relayer,
        bool isSlowFill
    ) external {
        _fillRelayV3(relayExecution, relayer, isSlowFill);
    }
}

contract Tron_SpokePoolTest is Test {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    Testable_Tron_SpokePool spokePool;
    WETH9 weth;
    MockTronUSDT usdt;
    MintableERC20 vanilla;

    address owner = makeAddr("owner");
    address relayer = makeAddr("relayer");
    address recipient = makeAddr("recipient");
    address newRefundAddress = makeAddr("newRefundAddress");

    uint256 constant ORIGIN_CHAIN_ID = 1;
    uint256 constant DEST_CHAIN_ID = 728126428; // Tron

    function setUp() public {
        weth = new WETH9();
        usdt = new MockTronUSDT();
        vanilla = new MintableERC20("Vanilla", "VAN", 6);

        Testable_Tron_SpokePool impl = new Testable_Tron_SpokePool(
            1 days,
            makeAddr("helios"),
            makeAddr("hubPoolStore"),
            address(weth),
            1 hours,
            9 hours,
            IERC20(address(0)),
            ITokenMessenger(address(0)),
            0,
            0
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Universal_SpokePool.initialize, (0, owner, makeAddr("withdrawalRecipient")))
        );
        spokePool = Testable_Tron_SpokePool(payable(proxy));
    }

    // ───────────────────────── _distributeRelayerRefunds ─────────────────────────

    function test_DistributeRefunds_TronUSDT_NoPhantomEntries() public {
        uint256 amount = 100e6;
        usdt.mint(address(spokePool), amount);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        address[] memory refundees = new address[](1);
        refundees[0] = relayer;

        spokePool.distributeRelayerRefundsExternal(DEST_CHAIN_ID, 0, amounts, 0, address(usdt), refundees);

        assertEq(usdt.balanceOf(relayer), amount, "Relayer should have received the refund");
        assertEq(spokePool.getRelayerRefund(address(usdt), relayer), 0, "No phantom entry expected");
    }

    function test_DistributeRefunds_TronUSDT_PhantomEntryOnGenuineFailure() public {
        uint256 amount = 100e6;
        usdt.mint(address(spokePool), amount);
        usdt.setBlacklisted(relayer, true);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        address[] memory refundees = new address[](1);
        refundees[0] = relayer;

        spokePool.distributeRelayerRefundsExternal(DEST_CHAIN_ID, 0, amounts, 0, address(usdt), refundees);

        assertEq(usdt.balanceOf(relayer), 0, "Blacklisted relayer should not have received funds");
        assertEq(
            spokePool.getRelayerRefund(address(usdt), relayer),
            amount,
            "Phantom entry should be created on genuine failure"
        );
    }

    function test_DistributeRefunds_VanillaERC20_NoPhantomEntries() public {
        uint256 amount = 100e6;
        vanilla.mint(address(spokePool), amount);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        address[] memory refundees = new address[](1);
        refundees[0] = relayer;

        spokePool.distributeRelayerRefundsExternal(DEST_CHAIN_ID, 0, amounts, 0, address(vanilla), refundees);

        assertEq(vanilla.balanceOf(relayer), amount);
        assertEq(spokePool.getRelayerRefund(address(vanilla), relayer), 0);
    }

    // ───────────────────────── claimRelayerRefund ─────────────────────────

    function test_ClaimRelayerRefund_TronUSDT_Succeeds() public {
        uint256 amount = 100e6;
        usdt.mint(address(spokePool), amount);
        // Force a phantom entry by blacklisting the relayer during distribution.
        usdt.setBlacklisted(relayer, true);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        address[] memory refundees = new address[](1);
        refundees[0] = relayer;
        spokePool.distributeRelayerRefundsExternal(DEST_CHAIN_ID, 0, amounts, 0, address(usdt), refundees);

        assertEq(spokePool.getRelayerRefund(address(usdt), relayer), amount, "phantom should exist");

        // Unblacklist relayer; claim sends to a new refund address.
        usdt.setBlacklisted(relayer, false);

        vm.prank(relayer);
        spokePool.claimRelayerRefund(address(usdt).toBytes32(), newRefundAddress.toBytes32());

        assertEq(usdt.balanceOf(newRefundAddress), amount, "Refund address should receive tokens");
        assertEq(spokePool.getRelayerRefund(address(usdt), relayer), 0, "Phantom entry should be cleared");
    }

    function test_ClaimRelayerRefund_TronUSDT_RevertsWhenTransferFails() public {
        uint256 amount = 100e6;
        usdt.mint(address(spokePool), amount);
        usdt.setBlacklisted(relayer, true);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        address[] memory refundees = new address[](1);
        refundees[0] = relayer;
        spokePool.distributeRelayerRefundsExternal(DEST_CHAIN_ID, 0, amounts, 0, address(usdt), refundees);

        // Refund recipient is also blacklisted so the underlying transfer reverts.
        usdt.setBlacklisted(newRefundAddress, true);
        usdt.setBlacklisted(relayer, false);

        vm.prank(relayer);
        vm.expectRevert(Tron_SpokePool.TronTransferFailed.selector);
        spokePool.claimRelayerRefund(address(usdt).toBytes32(), newRefundAddress.toBytes32());
    }

    // ───────────────────────── _transferTokensToRecipient (slow fill) ─────────────────────────

    function test_SlowFill_TronUSDT_PaysRecipient() public {
        uint256 amount = 50e6;
        usdt.mint(address(spokePool), amount);

        V3SpokePoolInterface.V3RelayData memory relayData = _buildRelayData(address(usdt), recipient, amount);
        V3SpokePoolInterface.V3RelayExecutionParams memory exec = V3SpokePoolInterface.V3RelayExecutionParams({
            relay: relayData,
            relayHash: keccak256("slowfill-tron-usdt"),
            updatedOutputAmount: amount,
            updatedRecipient: recipient.toBytes32(),
            updatedMessage: "",
            repaymentChainId: DEST_CHAIN_ID
        });

        vm.prank(relayer);
        spokePool.fillRelayV3External(exec, relayer.toBytes32(), true);

        assertEq(usdt.balanceOf(recipient), amount, "Recipient should receive USDT on slow fill");
    }

    function test_SlowFill_TronUSDT_RevertsOnGenuineFailure() public {
        uint256 amount = 50e6;
        usdt.mint(address(spokePool), amount);
        usdt.setBlacklisted(recipient, true);

        V3SpokePoolInterface.V3RelayData memory relayData = _buildRelayData(address(usdt), recipient, amount);
        V3SpokePoolInterface.V3RelayExecutionParams memory exec = V3SpokePoolInterface.V3RelayExecutionParams({
            relay: relayData,
            relayHash: keccak256("slowfill-tron-usdt-fail"),
            updatedOutputAmount: amount,
            updatedRecipient: recipient.toBytes32(),
            updatedMessage: "",
            repaymentChainId: DEST_CHAIN_ID
        });

        vm.prank(relayer);
        vm.expectRevert(Tron_SpokePool.TronTransferFailed.selector);
        spokePool.fillRelayV3External(exec, relayer.toBytes32(), true);
    }

    function test_SlowFill_VanillaERC20_PaysRecipient() public {
        uint256 amount = 50e6;
        vanilla.mint(address(spokePool), amount);

        V3SpokePoolInterface.V3RelayData memory relayData = _buildRelayData(address(vanilla), recipient, amount);
        V3SpokePoolInterface.V3RelayExecutionParams memory exec = V3SpokePoolInterface.V3RelayExecutionParams({
            relay: relayData,
            relayHash: keccak256("slowfill-vanilla"),
            updatedOutputAmount: amount,
            updatedRecipient: recipient.toBytes32(),
            updatedMessage: "",
            repaymentChainId: DEST_CHAIN_ID
        });

        vm.prank(relayer);
        spokePool.fillRelayV3External(exec, relayer.toBytes32(), true);

        assertEq(vanilla.balanceOf(recipient), amount);
    }

    // ─────────────────────────── helpers ───────────────────────────

    function _buildRelayData(
        address outputToken,
        address recipient_,
        uint256 amount
    ) internal view returns (V3SpokePoolInterface.V3RelayData memory) {
        return
            V3SpokePoolInterface.V3RelayData({
                depositor: relayer.toBytes32(),
                recipient: recipient_.toBytes32(),
                exclusiveRelayer: bytes32(0),
                inputToken: outputToken.toBytes32(),
                outputToken: outputToken.toBytes32(),
                inputAmount: amount,
                outputAmount: amount,
                originChainId: ORIGIN_CHAIN_ID,
                depositId: 1,
                fillDeadline: uint32(block.timestamp + 1 hours),
                exclusivityDeadline: 0,
                message: ""
            });
    }
}
