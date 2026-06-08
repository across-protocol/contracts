// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    CounterfactualDepositOFT,
    OFTRouteParams,
    OFTSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { CounterfactualImplementationBase } from "../../../../contracts/periphery/counterfactual/CounterfactualImplementationBase.sol";
import { CounterfactualChainConfig } from "../../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/// @notice Mock SponsoredOFTSrcPeriphery: pulls `token`, asserts the quote's srcEid, and records the quote.
contract MockOFTPeriphery {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    uint32 public immutable expectedSrcEid;
    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMsgValue;
    uint256 public callCount;

    constructor(IERC20 _token, uint32 _expectedSrcEid) {
        token = _token;
        expectedSrcEid = _expectedSrcEid;
    }

    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata) external payable {
        require(quote.signedParams.srcEid == expectedSrcEid, "unexpected srcEid");
        token.safeTransferFrom(msg.sender, address(this), quote.signedParams.amountLD);
        lastAmount = quote.signedParams.amountLD;
        lastNonce = quote.signedParams.nonce;
        lastMsgValue = msg.value;
        callCount++;
    }
}

contract CounterfactualDepositOFTTest is CounterfactualTestBase {
    CounterfactualDepositOFT internal oftImpl;
    MockOFTPeriphery internal periphery;
    MintableERC20 internal token;

    uint32 constant SRC_EID = 30101;
    bytes32 constant EXECUTE_OFT_TYPEHASH =
        keccak256("ExecuteOFT(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

    function setUp() public {
        _setUpCore();

        // Mocks must exist before the beacon is deployed, since the beacon config points at them.
        token = new MintableERC20("USDC", "USDC", 6);
        periphery = new MockOFTPeriphery(IERC20(address(token)), SRC_EID);
        oftImpl = new CounterfactualDepositOFT();

        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.oftSrcPeriphery = address(periphery);
        cfg.oftSrcEid = SRC_EID;
        cfg.usdc = address(token); // the impl resolves the input token as beacon.usdc()
        _deployBeacon(cfg);

        token.mint(user, 1000e6);
    }

    function _routeParams() internal returns (OFTRouteParams memory) {
        return
            OFTRouteParams({
                dstEid: 30362,
                destinationHandler: bytes32(uint256(uint160(makeAddr("handler")))),
                maxOftFeeBps: 100,
                lzReceiveGasLimit: 200000,
                lzComposeGasLimit: 500000,
                maxBpsToSponsor: 500,
                maxUserSlippageBps: 50,
                finalRecipient: bytes32(uint256(uint160(makeAddr("finalRecipient")))),
                finalToken: bytes32(uint256(uint160(address(token)))),
                destinationDex: 0,
                accountCreationMode: 0,
                executionMode: 0,
                refundRecipient: makeAddr("refund"),
                actionData: "",
                maxExecutionFee: 5e6
            });
    }

    function _deploy(bytes memory route, bytes32 salt) internal returns (address proxy, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(oftImpl), route);
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
        bytes32 structHash = keccak256(abi.encode(EXECUTE_OFT_TYPEHASH, nonce, executionFee, signatureDeadline));
        bytes memory cfSig = _sign(pk, _domainSeparator("CounterfactualDepositOFT", proxy), structHash);
        return
            abi.encode(
                OFTSubmitterData({
                    amount: amount,
                    executionFeeRecipient: relayer,
                    nonce: nonce,
                    oftDeadline: block.timestamp + 1 hours,
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
        ICounterfactualDeposit(proxy).execute(address(oftImpl), route, submitter, proof);

        assertEq(periphery.lastAmount(), amount - fee);
        assertEq(periphery.lastNonce(), nonce);
        assertEq(token.balanceOf(relayer), fee);
        assertEq(token.balanceOf(proxy), 0);
    }

    function testDepositForwardsMsgValue() public {
        bytes memory route = abi.encode(_routeParams());
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
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute{ value: 0.05 ether }(address(oftImpl), route, submitter, proof);

        assertEq(periphery.lastMsgValue(), 0.05 ether);
    }

    function testZeroExecutionFee() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(proxy, 100e6, keccak256("n"), 0, uint32(block.timestamp) + 3600, signerPk);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(oftImpl), route, submitter, proof);

        assertEq(periphery.lastAmount(), 100e6);
        assertEq(token.balanceOf(relayer), 0);
    }

    function testMaxExecutionFeeReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
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
        vm.expectRevert(CounterfactualDepositOFT.MaxExecutionFee.selector);
        ICounterfactualDeposit(proxy).execute(address(oftImpl), route, submitter, proof);
    }

    function testInvalidSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(proxy, 100e6, keccak256("n"), 1e6, uint32(block.timestamp) + 3600, 0xBEEF);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositOFT.InvalidSignature.selector);
        ICounterfactualDeposit(proxy).execute(address(oftImpl), route, submitter, proof);
    }

    function testExpiredSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(proxy, 100e6, keccak256("n"), 1e6, uint32(block.timestamp) + 100, signerPk);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.warp(block.timestamp + 101);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositOFT.SignatureExpired.selector);
        ICounterfactualDeposit(proxy).execute(address(oftImpl), route, submitter, proof);
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
        ICounterfactualDeposit(proxyA).execute(address(oftImpl), route, submitter, proofA);

        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositOFT.InvalidSignature.selector);
        ICounterfactualDeposit(proxyB).execute(address(oftImpl), route, submitter, proofB);
    }
}
