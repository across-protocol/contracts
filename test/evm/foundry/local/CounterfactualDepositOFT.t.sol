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
import { ICounterfactualBeacon } from "../../../../contracts/interfaces/ICounterfactualBeacon.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/// @notice Mock SponsoredOFTSrcPeriphery: pulls `TOKEN`, asserts the quote's srcEid, records the quote.
/// @dev Exposes `TOKEN()` to mirror the real periphery's immutable getter, which the leaf impl reads to
///      resolve the input token.
contract MockOFTPeriphery {
    using SafeERC20 for IERC20;

    // solhint-disable-next-line var-name-mixedcase
    address public immutable TOKEN;
    uint32 public immutable expectedSrcEid;
    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMsgValue;
    uint256 public callCount;

    constructor(IERC20 _token, uint32 _expectedSrcEid) {
        TOKEN = address(_token);
        expectedSrcEid = _expectedSrcEid;
    }

    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata) external payable {
        require(quote.signedParams.srcEid == expectedSrcEid, "unexpected srcEid");
        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), quote.signedParams.amountLD);
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

    /// @dev Selector the OFT leaf names to pick the (single-token) OFT periphery; more OFT tokens = more
    ///      beacon periphery getters, each named by its own selector.
    bytes4 constant OFT_GETTER = ICounterfactualBeacon.oftSrcPeriphery.selector;

    uint32 constant SRC_EID = 30101;
    bytes32 constant EXECUTE_OFT_TYPEHASH =
        keccak256("ExecuteOFT(bytes32 routeParamsHash,bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

    function setUp() public {
        _setUpCore();

        // Mock must exist before the beacon, which points its config at it.
        token = new MintableERC20("USDT0", "USDT0", 6);
        periphery = new MockOFTPeriphery(IERC20(address(token)), SRC_EID);
        oftImpl = new CounterfactualDepositOFT();

        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.oftSrcPeriphery = address(periphery);
        cfg.oftSrcEid = SRC_EID;
        cfg.usdtOftMaxExecutionFee = 5e6;
        // The impl resolves the input token from the periphery's `TOKEN`, not `beacon.usdc()`.
        _deployBeacon(cfg);

        token.mint(user, 1000e6);
    }

    function _routeParams(bytes4 peripheryGetter) internal returns (OFTRouteParams memory) {
        return
            OFTRouteParams({
                peripheryGetter: peripheryGetter,
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
                maxExecutionFeeGetter: ICounterfactualBeacon.usdtOftMaxExecutionFee.selector
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
        bytes memory route,
        uint256 amount,
        bytes32 nonce,
        uint256 executionFee,
        uint32 signatureDeadline,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_OFT_TYPEHASH, keccak256(route), nonce, executionFee, signatureDeadline)
        );
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
        bytes memory route = abi.encode(_routeParams(OFT_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        uint256 amount = 100e6;
        uint256 fee = 1e6;
        bytes32 nonce = keccak256("n1");
        bytes memory submitter = _submitter(proxy, route, amount, nonce, fee, uint32(block.timestamp) + 3600, signerPk);

        vm.prank(user);
        token.transfer(proxy, amount);

        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(oftImpl), route, submitter, proof);

        assertEq(periphery.lastAmount(), amount - fee);
        assertEq(periphery.lastNonce(), nonce);
        assertEq(token.balanceOf(relayer), fee);
        assertEq(token.balanceOf(proxy), 0);
    }

    /// @dev The periphery is resolved from the leaf's selector, not hardcoded: a leaf whose `peripheryGetter`
    ///      resolves to address(0) on this chain's beacon reverts `RouteNotConfigured`. (Additional OFT
    ///      tokens are supported by adding more beacon periphery getters, each named by its own selector.)
    function testRouteNotConfiguredReverts() public {
        // Redeploy the beacon with the OFT periphery unset.
        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.oftSrcEid = SRC_EID;
        cfg.usdtOftMaxExecutionFee = 5e6; // set so the fee check passes; the revert is from the unset periphery
        _deployBeacon(cfg);

        bytes memory route = abi.encode(_routeParams(OFT_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(
            proxy,
            route,
            100e6,
            keccak256("n"),
            1e6,
            uint32(block.timestamp) + 3600,
            signerPk
        );

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualImplementationBase.RouteNotConfigured.selector);
        ICounterfactualDeposit(proxy).execute(address(oftImpl), route, submitter, proof);
    }

    function testDepositForwardsMsgValue() public {
        bytes memory route = abi.encode(_routeParams(OFT_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(
            proxy,
            route,
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
        bytes memory route = abi.encode(_routeParams(OFT_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(
            proxy,
            route,
            100e6,
            keccak256("n"),
            0,
            uint32(block.timestamp) + 3600,
            signerPk
        );

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(oftImpl), route, submitter, proof);

        assertEq(periphery.lastAmount(), 100e6);
        assertEq(token.balanceOf(relayer), 0);
    }

    function testMaxExecutionFeeReverts() public {
        bytes memory route = abi.encode(_routeParams(OFT_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(
            proxy,
            route,
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
        bytes memory route = abi.encode(_routeParams(OFT_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(
            proxy,
            route,
            100e6,
            keccak256("n"),
            1e6,
            uint32(block.timestamp) + 3600,
            0xBEEF
        );

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositOFT.InvalidSignature.selector);
        ICounterfactualDeposit(proxy).execute(address(oftImpl), route, submitter, proof);
    }

    function testExpiredSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams(OFT_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(
            proxy,
            route,
            100e6,
            keccak256("n"),
            1e6,
            uint32(block.timestamp) + 100,
            signerPk
        );

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.warp(block.timestamp + 101);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositOFT.SignatureExpired.selector);
        ICounterfactualDeposit(proxy).execute(address(oftImpl), route, submitter, proof);
    }

    function testCrossProxyReplayReverts() public {
        bytes memory route = abi.encode(_routeParams(OFT_GETTER));
        (address proxyA, bytes32[] memory proofA) = _deploy(route, keccak256("a"));
        (address proxyB, bytes32[] memory proofB) = _deploy(route, keccak256("b"));
        bytes memory submitter = _submitter(
            proxyA,
            route,
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

    /// @dev A fee signature for one OFT route does not validate for a different route on the SAME proxy:
    ///      `routeParamsHash` (which includes `peripheryGetter`) is bound in the fee signature. This is what
    ///      lets one tree safely hold multiple OFT leaves — e.g. different input tokens via different
    ///      periphery getters — to a single destination identity.
    function testCrossRouteSignatureReverts() public {
        OFTRouteParams memory rpA = _routeParams(OFT_GETTER);
        OFTRouteParams memory rpB = _routeParams(OFT_GETTER);
        rpB.dstEid = rpA.dstEid + 1; // distinct route, same impl
        bytes memory routeA = abi.encode(rpA);
        bytes memory routeB = abi.encode(rpB);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(oftImpl), routeA);
        leaves[1] = _leaf(address(oftImpl), routeB);
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proofB = merkle.getProof(leaves, 1);
        address proxy = factory.deploy(bytes32(0), root);

        // Sign for routeA, attempt to execute routeB.
        bytes memory submitter = _submitter(
            proxy,
            routeA,
            100e6,
            keccak256("n"),
            1e6,
            uint32(block.timestamp) + 3600,
            signerPk
        );

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.expectRevert(CounterfactualDepositOFT.InvalidSignature.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(oftImpl), routeB, submitter, proofB);
    }
}
