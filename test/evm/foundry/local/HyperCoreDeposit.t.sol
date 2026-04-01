// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { HyperCoreDeposit } from "../../../../contracts/test-hypercore/HyperCoreDeposit.sol";
import { HyperCoreMockHelper } from "./HyperCoreMockHelper.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";

contract HyperCoreDepositTest is HyperCoreMockHelper {
    HyperCoreDeposit deposit;
    MintableERC20 usdc;

    address owner;
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address mockSpokePool = makeAddr("spokePool");
    address mockCCTPPeriphery = makeAddr("cctpPeriphery");
    address mockOFTPeriphery = makeAddr("oftPeriphery");

    uint64 constant USDC_TOKEN_INDEX = 0;
    uint256 constant INPUT_AMOUNT = 1000e6;
    uint64 constant HL_NONCE = 1710000000000; // example unix ms

    function setUp() public {
        owner = address(this);
        usdc = new MintableERC20("USDC", "USDC", 6);
        deposit = new HyperCoreDeposit(owner);
        deposit.setSpokePool(mockSpokePool);
        deposit.setCCTPPeriphery(mockCCTPPeriphery);
        deposit.setOFTPeriphery(mockOFTPeriphery);

        // Fund the deposit contract (simulates pullFunds already happened).
        usdc.mint(address(deposit), INPUT_AMOUNT);

        setupDefaultHyperCoreMocks(address(usdc), "USDC", 6);
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _defaultSpokePoolParams() internal view returns (HyperCoreDeposit.SpokePoolParams memory) {
        return
            HyperCoreDeposit.SpokePoolParams({
                depositor: user,
                recipient: recipient,
                inputToken: address(usdc),
                outputToken: address(usdc),
                inputAmount: INPUT_AMOUNT,
                outputAmount: 995e6,
                destinationChainId: 1,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 6 hours),
                exclusivityDeadline: 0
            });
    }

    bytes4 constant DEPOSIT_V3_SELECTOR =
        bytes4(
            keccak256(
                "depositV3(address,address,address,address,uint256,uint256,uint256,address,uint32,uint32,uint32,bytes)"
            )
        );

    bytes4 constant CCTP_DEPOSIT_SELECTOR =
        bytes4(
            keccak256(
                "depositForBurn((uint32,uint32,bytes32,uint256,bytes32,bytes32,uint256,uint32,bytes32,uint256,uint256,uint256,bytes32,bytes32,uint32,uint8,uint8,bytes),bytes)"
            )
        );

    bytes4 constant OFT_DEPOSIT_SELECTOR =
        bytes4(
            keccak256(
                "deposit(((uint32,uint32,bytes32,uint256,bytes32,uint256,uint256,uint256,bytes32,bytes32,uint32,uint256,uint256,uint256,uint8,uint8,bytes),(address)),bytes)"
            )
        );

    // ─── pullFunds ───────────────────────────────────────────────────

    function testPullFunds() public {
        deposit.pullFunds(USDC_TOKEN_INDEX, 1000e6);
    }

    function testPullFundsRevertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(HyperCoreDeposit.NotOwner.selector);
        deposit.pullFunds(USDC_TOKEN_INDEX, 1000e6);
    }

    // ─── executeSpokePool ────────────────────────────────────────────

    function testExecuteSpokePool() public {
        vm.etch(mockSpokePool, hex"00");
        vm.mockCall(mockSpokePool, abi.encodeWithSelector(DEPOSIT_V3_SELECTOR), abi.encode());

        deposit.executeSpokePool(HL_NONCE, _defaultSpokePoolParams());

        assertTrue(deposit.usedNonces(HL_NONCE));
    }

    function testExecuteSpokePoolRevertsOnReplay() public {
        vm.etch(mockSpokePool, hex"00");
        vm.mockCall(mockSpokePool, abi.encodeWithSelector(DEPOSIT_V3_SELECTOR), abi.encode());

        deposit.executeSpokePool(HL_NONCE, _defaultSpokePoolParams());

        vm.expectRevert(HyperCoreDeposit.NonceAlreadyUsed.selector);
        deposit.executeSpokePool(HL_NONCE, _defaultSpokePoolParams());
    }

    function testExecuteSpokePoolRevertsWhenNotConfigured() public {
        HyperCoreDeposit freshDeposit = new HyperCoreDeposit(owner);
        usdc.mint(address(freshDeposit), INPUT_AMOUNT);

        vm.expectRevert(HyperCoreDeposit.TargetNotConfigured.selector);
        freshDeposit.executeSpokePool(HL_NONCE, _defaultSpokePoolParams());
    }

    function testExecuteSpokePoolRevertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(HyperCoreDeposit.NotOwner.selector);
        deposit.executeSpokePool(HL_NONCE, _defaultSpokePoolParams());
    }

    // ─── executeCCTP ─────────────────────────────────────────────────

    function testExecuteCCTP() public {
        SponsoredCCTPInterface.SponsoredCCTPQuote memory cctpQuote = SponsoredCCTPInterface.SponsoredCCTPQuote({
            sourceDomain: 0,
            destinationDomain: 1,
            mintRecipient: bytes32(uint256(uint160(recipient))),
            amount: INPUT_AMOUNT,
            burnToken: bytes32(uint256(uint160(address(usdc)))),
            destinationCaller: bytes32(0),
            maxFee: 0,
            minFinalityThreshold: 0,
            nonce: bytes32(uint256(HL_NONCE)),
            deadline: block.timestamp + 1 hours,
            maxBpsToSponsor: 0,
            maxUserSlippageBps: 0,
            finalRecipient: bytes32(uint256(uint160(recipient))),
            finalToken: bytes32(uint256(uint160(address(usdc)))),
            destinationDex: type(uint32).max,
            accountCreationMode: 0,
            executionMode: 0,
            actionData: bytes("")
        });

        vm.etch(mockCCTPPeriphery, hex"00");
        vm.mockCall(mockCCTPPeriphery, abi.encodeWithSelector(CCTP_DEPOSIT_SELECTOR), abi.encode());

        deposit.executeCCTP(HL_NONCE, address(usdc), INPUT_AMOUNT, cctpQuote, bytes("cctpSig"));

        assertTrue(deposit.usedNonces(HL_NONCE));
    }

    // ─── executeOFT ──────────────────────────────────────────────────

    function testExecuteOFT() public {
        SponsoredOFTInterface.Quote memory oftQuote = SponsoredOFTInterface.Quote({
            signedParams: SponsoredOFTInterface.SignedQuoteParams({
                srcEid: 1,
                dstEid: 2,
                destinationHandler: bytes32(uint256(uint160(recipient))),
                amountLD: INPUT_AMOUNT,
                nonce: bytes32(uint256(HL_NONCE)),
                deadline: block.timestamp + 1 hours,
                maxBpsToSponsor: 0,
                maxUserSlippageBps: 0,
                finalRecipient: bytes32(uint256(uint160(recipient))),
                finalToken: bytes32(uint256(uint160(address(usdc)))),
                destinationDex: type(uint32).max,
                lzReceiveGasLimit: 200_000,
                lzComposeGasLimit: 200_000,
                maxOftFeeBps: 0,
                accountCreationMode: 0,
                executionMode: 0,
                actionData: bytes("")
            }),
            unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({ refundRecipient: owner })
        });

        vm.etch(mockOFTPeriphery, hex"00");
        vm.mockCall(mockOFTPeriphery, abi.encodeWithSelector(OFT_DEPOSIT_SELECTOR), abi.encode());

        deposit.executeOFT(HL_NONCE, address(usdc), INPUT_AMOUNT, oftQuote, bytes("oftSig"));

        assertTrue(deposit.usedNonces(HL_NONCE));
    }

    // ─── Admin ───────────────────────────────────────────────────────

    function testSetOwner() public {
        address newOwner = makeAddr("newOwner");
        deposit.setOwner(newOwner);
        assertEq(deposit.owner(), newOwner);
    }

    function testSetOwnerRevertsZeroAddress() public {
        vm.expectRevert(HyperCoreDeposit.ZeroAddress.selector);
        deposit.setOwner(address(0));
    }

    function testSweepERC20() public {
        address to = makeAddr("sweepTo");
        deposit.sweepERC20(address(usdc), to);
        assertEq(usdc.balanceOf(to), INPUT_AMOUNT);
    }

    function testSweepERC20RevertsWhenEmpty() public {
        deposit.sweepERC20(address(usdc), owner);
        vm.expectRevert(HyperCoreDeposit.NothingToSweep.selector);
        deposit.sweepERC20(address(usdc), owner);
    }

    function testSweepNative() public {
        vm.deal(address(deposit), 1 ether);
        address payable to = payable(makeAddr("sweepTo"));
        deposit.sweepNative(to);
        assertEq(to.balance, 1 ether);
    }

    function testCoreBalance() public view {
        uint64 bal = deposit.coreBalance(USDC_TOKEN_INDEX);
        assertEq(bal, 10e8);
    }
}
