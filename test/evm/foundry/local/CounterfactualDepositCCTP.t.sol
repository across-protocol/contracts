// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    CounterfactualDepositCCTP,
    CCTPRouteParams,
    CCTPSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/// @notice Mock SponsoredCCTPSrcPeriphery: pulls the burn token and records the quote.
contract MockCCTPPeriphery {
    using SafeERC20 for IERC20;

    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMaxFee;
    uint256 public callCount;

    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory) external {
        IERC20(address(uint160(uint256(quote.burnToken)))).safeTransferFrom(msg.sender, address(this), quote.amount);
        lastAmount = quote.amount;
        lastNonce = quote.nonce;
        lastMaxFee = quote.maxFee;
        callCount++;
    }
}

contract CounterfactualDepositCCTPTest is CounterfactualTestBase {
    CounterfactualDepositCCTP internal cctpImpl;
    MockCCTPPeriphery internal periphery;
    MintableERC20 internal token;

    uint32 constant SOURCE_DOMAIN = 0;
    bytes32 constant EXECUTE_CCTP_TYPEHASH =
        keccak256("ExecuteCCTP(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

    function setUp() public {
        _setUpCore();
        periphery = new MockCCTPPeriphery();
        cctpImpl = new CounterfactualDepositCCTP(address(periphery), SOURCE_DOMAIN, signer);
        token = new MintableERC20("USDC", "USDC", 6);
        token.mint(user, 1000e6);
    }

    function _routeParams() internal returns (CCTPRouteParams memory) {
        return
            CCTPRouteParams({
                sourceChainId: block.chainid,
                destinationDomain: 3,
                mintRecipient: bytes32(uint256(uint160(makeAddr("mintRecipient")))),
                burnToken: bytes32(uint256(uint160(address(token)))),
                destinationCaller: bytes32(uint256(uint160(makeAddr("caller")))),
                cctpMaxFeeBps: 100,
                minFinalityThreshold: 1000,
                maxBpsToSponsor: 500,
                maxUserSlippageBps: 50,
                finalRecipient: bytes32(uint256(uint160(makeAddr("finalRecipient")))),
                finalToken: bytes32(uint256(uint160(address(token)))),
                destinationDex: 0,
                accountCreationMode: 0,
                executionMode: 0,
                actionData: "",
                maxExecutionFee: 5e6
            });
    }

    function _deploy(bytes memory route, bytes32 salt) internal returns (address proxy, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(cctpImpl), route);
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        proof = merkle.getProof(leaves, 0);
        proxy = factory.deploy(salt, root);
    }

    function _submitter(
        address proxy,
        uint256 amount,
        bytes32 nonce,
        uint256 executionFee,
        uint32 signatureDeadline,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(EXECUTE_CCTP_TYPEHASH, nonce, executionFee, signatureDeadline));
        bytes memory cfSig = _sign(pk, _domainSeparator("CounterfactualDepositCCTP", proxy), structHash);
        return
            abi.encode(
                CCTPSubmitterData({
                    amount: amount,
                    executionFeeRecipient: relayer,
                    nonce: nonce,
                    cctpDeadline: block.timestamp + 1 hours,
                    executionFee: executionFee,
                    signatureDeadline: signatureDeadline,
                    peripherySignature: "periphery-sig",
                    counterfactualSignature: cfSig
                })
            );
    }

    function testDeposit() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        uint256 amount = 100e6;
        uint256 fee = 1e6;
        bytes32 nonce = keccak256("n1");
        bytes memory submitter = _submitter(proxy, amount, nonce, fee, uint32(block.timestamp) + 3600, signerPk);

        vm.prank(user);
        token.transfer(proxy, amount);

        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(cctpImpl), route, submitter, proof);

        assertEq(periphery.lastAmount(), amount - fee);
        assertEq(periphery.lastNonce(), nonce);
        assertEq(periphery.lastMaxFee(), ((amount - fee) * 100) / 10000);
        assertEq(token.balanceOf(relayer), fee);
        assertEq(token.balanceOf(proxy), 0);
    }

    function testZeroExecutionFee() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(proxy, 100e6, keccak256("n"), 0, uint32(block.timestamp) + 3600, signerPk);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(cctpImpl), route, submitter, proof);

        assertEq(periphery.lastAmount(), 100e6);
        assertEq(token.balanceOf(relayer), 0);
    }

    function testMaxExecutionFeeReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        // 6e6 > maxExecutionFee 5e6
        bytes memory submitter = _submitter(
            proxy,
            100e6,
            keccak256("n"),
            6e6,
            uint32(block.timestamp) + 3600,
            signerPk
        );

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositCCTP.MaxExecutionFee.selector);
        ICounterfactualDeposit(proxy).execute(address(cctpImpl), route, submitter, proof);
    }

    function testInvalidSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(proxy, 100e6, keccak256("n"), 1e6, uint32(block.timestamp) + 3600, 0xBEEF);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositCCTP.InvalidSignature.selector);
        ICounterfactualDeposit(proxy).execute(address(cctpImpl), route, submitter, proof);
    }

    function testExpiredSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(proxy, 100e6, keccak256("n"), 1e6, uint32(block.timestamp) + 100, signerPk);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.warp(block.timestamp + 101);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositCCTP.SignatureExpired.selector);
        ICounterfactualDeposit(proxy).execute(address(cctpImpl), route, submitter, proof);
    }

    function testSourceChainMismatchReverts() public {
        CCTPRouteParams memory rp = _routeParams();
        rp.sourceChainId = block.chainid + 1;
        bytes memory route = abi.encode(rp);
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(
            proxy,
            100e6,
            keccak256("n"),
            1e6,
            uint32(block.timestamp) + 3600,
            signerPk
        );

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositCCTP.SourceChainMismatch.selector);
        ICounterfactualDeposit(proxy).execute(address(cctpImpl), route, submitter, proof);
    }

    function testCrossProxyReplayReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxyA, bytes32[] memory proofA) = _deploy(route, keccak256("a"));
        (address proxyB, bytes32[] memory proofB) = _deploy(route, keccak256("b"));
        bytes memory submitter = _submitter(
            proxyA,
            100e6,
            keccak256("n"),
            1e6,
            uint32(block.timestamp) + 3600,
            signerPk
        );

        vm.prank(user);
        token.transfer(proxyA, 100e6);
        vm.prank(user);
        token.transfer(proxyB, 100e6);

        vm.prank(relayer);
        ICounterfactualDeposit(proxyA).execute(address(cctpImpl), route, submitter, proofA);

        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositCCTP.InvalidSignature.selector);
        ICounterfactualDeposit(proxyB).execute(address(cctpImpl), route, submitter, proofB);
    }
}
