// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    CounterfactualDepositVanillaCCTP,
    VanillaCCTPRouteParams,
    VanillaCCTPSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositVanillaCCTP.sol";
import { CounterfactualImplementationBase } from "../../../../contracts/periphery/counterfactual/CounterfactualImplementationBase.sol";
import { CounterfactualChainConfig } from "../../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { ICounterfactualBeacon } from "../../../../contracts/interfaces/ICounterfactualBeacon.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/// @notice Mock Circle CCTP v2 TokenMessenger: pulls the burn token and records the last call, including
///         whether the hook variant was used and the forwarded hookData.
contract MockTokenMessengerV2 {
    using SafeERC20 for IERC20;

    bool public lastWithHook;
    uint256 public lastAmount;
    uint32 public lastDestinationDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32 public lastMinFinalityThreshold;
    bytes public lastHookData;
    uint256 public callCount;

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), amount);
        lastWithHook = false;
        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastHookData = "";
        callCount++;
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), amount);
        lastWithHook = true;
        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastHookData = hookData;
        callCount++;
    }
}

contract CounterfactualDepositVanillaCCTPTest is CounterfactualTestBase {
    CounterfactualDepositVanillaCCTP internal vanillaImpl;
    MockTokenMessengerV2 internal messenger;
    MintableERC20 internal token;

    uint32 constant HYPEREVM_DOMAIN = 19;
    bytes32 constant EXECUTE_VANILLA_CCTP_TYPEHASH =
        keccak256(
            "ExecuteVanillaCCTP(bytes32 routeParamsHash,uint256 amount,uint256 executionFee,uint256 maxFeeCctp,uint32 minFinalityThreshold,uint32 signatureDeadline)"
        );

    function setUp() public {
        _setUpCore();
        // Mocks must exist before the beacon, which reads them from the chain config.
        messenger = new MockTokenMessengerV2();
        token = new MintableERC20("USDC", "USDC", 6);
        vanillaImpl = new CounterfactualDepositVanillaCCTP();

        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.cctpTokenMessenger = address(messenger);
        cfg.usdc = address(token); // burn token
        cfg.usdcCctpMaxExecutionFee = 5e6;
        cfg.usdcCctpMaxFeeBps = 100; // cap on the submitter's maxFeeCctp: 1% of the burned amount
        _deployBeacon(cfg);

        token.mint(user, 1000e6);
    }

    /// @dev Plain CCTP route (empty hookData): USDC mints natively to `mintRecipient`.
    function _routeParams() internal returns (VanillaCCTPRouteParams memory) {
        return
            VanillaCCTPRouteParams({
                destinationDomain: 3,
                mintRecipient: bytes32(uint256(uint160(makeAddr("mintRecipient")))),
                destinationCaller: bytes32(uint256(uint160(makeAddr("caller")))),
                hookData: "",
                maxExecutionFeeGetter: ICounterfactualBeacon.usdcCctpMaxExecutionFee.selector,
                cctpMaxFeeBpsGetter: ICounterfactualBeacon.usdcCctpMaxFeeBps.selector
            });
    }

    /// @dev HyperCore route: burn to HyperEVM (domain 19) with `mintRecipient` = Circle's CctpForwarder and a
    ///      `CctpForwarderHookData` envelope (magic | version | len | recipient | destinationId).
    function _hyperCoreRouteParams() internal returns (VanillaCCTPRouteParams memory rp) {
        rp = _routeParams();
        rp.destinationDomain = HYPEREVM_DOMAIN;
        rp.mintRecipient = bytes32(uint256(uint160(makeAddr("cctpForwarder"))));
        rp.hookData = abi.encodePacked(
            bytes24("cctp-forward"), // magic
            uint32(0), // version
            uint32(24), // length (20-byte recipient + 4-byte destinationId)
            makeAddr("hyperCoreRecipient"), // forwardRecipient
            uint32(2) // destinationId
        );
    }

    function _deploy(bytes memory route, bytes32 salt) internal returns (address proxy, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(vanillaImpl), route);
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        proof = merkle.getProof(leaves, 0);
        proxy = factory.deploy(salt, root);
    }

    /// @dev Default runtime CCTP params: fast transfer with `maxFeeCctp = 1e5`, threshold 1000.
    function _submitter(
        address proxy,
        bytes memory route,
        uint256 amount,
        uint256 executionFee,
        uint32 signatureDeadline,
        uint256 pk
    ) internal view returns (bytes memory) {
        return _submitter(proxy, route, amount, executionFee, 1e5, 1000, signatureDeadline, pk);
    }

    function _submitter(
        address proxy,
        bytes memory route,
        uint256 amount,
        uint256 executionFee,
        uint256 maxFeeCctp,
        uint32 minFinalityThreshold,
        uint32 signatureDeadline,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_VANILLA_CCTP_TYPEHASH,
                keccak256(route),
                amount,
                executionFee,
                maxFeeCctp,
                minFinalityThreshold,
                signatureDeadline
            )
        );
        bytes memory sig = _sign(pk, _domainSeparator("CounterfactualDepositVanillaCCTP", proxy), structHash);
        return
            abi.encode(
                VanillaCCTPSubmitterData({
                    amount: amount,
                    executionFeeRecipient: relayer,
                    executionFee: executionFee,
                    maxFeeCctp: maxFeeCctp,
                    minFinalityThreshold: minFinalityThreshold,
                    signatureDeadline: signatureDeadline,
                    counterfactualSignature: sig
                })
            );
    }

    function testDepositPlainCCTP() public {
        VanillaCCTPRouteParams memory rp = _routeParams();
        bytes memory route = abi.encode(rp);
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        uint256 amount = 100e6;
        uint256 fee = 1e6;
        bytes memory submitter = _submitter(proxy, route, amount, fee, uint32(block.timestamp) + 3600, signerPk);

        vm.prank(user);
        token.transfer(proxy, amount);

        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);

        assertEq(messenger.lastWithHook(), false);
        assertEq(messenger.lastAmount(), amount - fee);
        assertEq(messenger.lastDestinationDomain(), rp.destinationDomain);
        assertEq(messenger.lastMintRecipient(), rp.mintRecipient);
        assertEq(messenger.lastBurnToken(), address(token));
        assertEq(messenger.lastDestinationCaller(), rp.destinationCaller);
        assertEq(messenger.lastMaxFee(), 1e5); // submitter-chosen, within the 1% bps cap
        assertEq(messenger.lastMinFinalityThreshold(), 1000);
        assertEq(token.balanceOf(relayer), fee);
        assertEq(token.balanceOf(proxy), 0);
        assertEq(messenger.callCount(), 1);
    }

    function testDepositHyperCore() public {
        VanillaCCTPRouteParams memory rp = _hyperCoreRouteParams();
        bytes memory route = abi.encode(rp);
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        uint256 amount = 100e6;
        uint256 fee = 1e6;
        bytes memory submitter = _submitter(proxy, route, amount, fee, uint32(block.timestamp) + 3600, signerPk);

        vm.prank(user);
        token.transfer(proxy, amount);

        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);

        assertEq(messenger.lastWithHook(), true);
        assertEq(messenger.lastAmount(), amount - fee);
        assertEq(messenger.lastDestinationDomain(), HYPEREVM_DOMAIN);
        assertEq(messenger.lastMintRecipient(), rp.mintRecipient);
        assertEq(messenger.lastBurnToken(), address(token));
        assertEq(messenger.lastMaxFee(), 1e5); // submitter-chosen, within the 1% bps cap
        assertEq(messenger.lastHookData(), rp.hookData);
        assertEq(token.balanceOf(proxy), 0);
    }

    function testZeroExecutionFee() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(proxy, route, 100e6, 0, uint32(block.timestamp) + 3600, signerPk);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);

        assertEq(messenger.lastAmount(), 100e6);
        assertEq(token.balanceOf(relayer), 0);
    }

    /// @dev The submitter picks a standard transfer at execution time: `maxFeeCctp = 0`, threshold 2000.
    function testStandardTransferZeroFee() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(
            proxy,
            route,
            100e6,
            1e6,
            0,
            2000,
            uint32(block.timestamp) + 3600,
            signerPk
        );

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);

        assertEq(messenger.lastMaxFee(), 0);
        assertEq(messenger.lastMinFinalityThreshold(), 2000);
    }

    function testMaxExecutionFeeReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        // 6e6 > cap 5e6.
        bytes memory submitter = _submitter(proxy, route, 100e6, 6e6, uint32(block.timestamp) + 3600, signerPk);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositVanillaCCTP.MaxExecutionFee.selector);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);
    }

    /// @dev `maxFeeCctp` is capped independently of the execution fee, at the beacon's bps of the burned
    ///      amount: above the cap reverts, exactly at the cap passes.
    function testMaxCctpFeeBoundary() public {
        bytes memory route = abi.encode(_routeParams()); // beacon usdcCctpMaxFeeBps = 100 (1%)
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        uint32 deadline = uint32(block.timestamp) + 3600;
        uint256 cap = ((100e6 - 1e6) * 100) / 10000; // 1% of the burned amount = 0.99e6

        vm.prank(user);
        token.transfer(proxy, 100e6);

        bytes memory submitter = _submitter(proxy, route, 100e6, 1e6, cap + 1, 1000, deadline, signerPk);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositVanillaCCTP.MaxCctpFee.selector);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);

        submitter = _submitter(proxy, route, 100e6, 1e6, cap, 1000, deadline, signerPk);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);
        assertEq(messenger.lastMaxFee(), cap);
    }

    function testInvalidSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(proxy, route, 100e6, 1e6, uint32(block.timestamp) + 3600, 0xBEEF);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositVanillaCCTP.InvalidSignature.selector);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);
    }

    function testExpiredSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(proxy, route, 100e6, 1e6, uint32(block.timestamp) + 100, signerPk);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.warp(block.timestamp + 101);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositVanillaCCTP.SignatureExpired.selector);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);
    }

    /// @dev When the beacon resolves USDC (the burn token) to zero, the route is not live and execution
    ///      reverts via `RouteNotConfigured` rather than acting on a zero address.
    function testRouteNotConfiguredReverts() public {
        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.cctpTokenMessenger = address(messenger);
        cfg.usdc = address(0); // unset burn token
        cfg.usdcCctpMaxExecutionFee = 5e6; // set so the fee checks pass; the revert is from usdc = 0
        cfg.usdcCctpMaxFeeBps = 100;
        _deployBeacon(cfg);

        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        bytes memory submitter = _submitter(proxy, route, 100e6, 1e6, uint32(block.timestamp) + 3600, signerPk);

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualImplementationBase.RouteNotConfigured.selector);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);
    }

    /// @dev The signature binds one proxy via the EIP-712 `verifyingContract`, so it can't be replayed
    ///      against another counterfactual sharing the route.
    function testCrossProxyReplayReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxyA, bytes32[] memory proofA) = _deploy(route, keccak256("a"));
        (address proxyB, bytes32[] memory proofB) = _deploy(route, keccak256("b"));
        bytes memory submitter = _submitter(proxyA, route, 100e6, 1e6, uint32(block.timestamp) + 3600, signerPk);

        vm.prank(user);
        token.transfer(proxyA, 100e6);
        vm.prank(user);
        token.transfer(proxyB, 100e6);

        vm.prank(relayer);
        ICounterfactualDeposit(proxyA).execute(address(vanillaImpl), route, submitter, proofA);

        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositVanillaCCTP.InvalidSignature.selector);
        ICounterfactualDeposit(proxyB).execute(address(vanillaImpl), route, submitter, proofB);
    }

    /// @dev The signature binds `amount`; submitting a different amount than was signed must revert.
    function testWrongAmountSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        uint32 deadline = uint32(block.timestamp) + 3600;
        // Sign 100e6, submit 200e6.
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_VANILLA_CCTP_TYPEHASH, keccak256(route), 100e6, 1e6, 1e5, uint32(1000), deadline)
        );
        bytes memory sig = _sign(signerPk, _domainSeparator("CounterfactualDepositVanillaCCTP", proxy), structHash);
        bytes memory submitter = abi.encode(
            VanillaCCTPSubmitterData({
                amount: 200e6,
                executionFeeRecipient: relayer,
                executionFee: 1e6,
                maxFeeCctp: 1e5,
                minFinalityThreshold: 1000,
                signatureDeadline: deadline,
                counterfactualSignature: sig
            })
        );

        vm.prank(user);
        token.transfer(proxy, 200e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositVanillaCCTP.InvalidSignature.selector);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);
    }

    /// @dev The signature binds `maxFeeCctp`/`minFinalityThreshold`; submitting different CCTP runtime
    ///      params than were signed must revert, even when they'd pass the bps cap.
    function testWrongCctpParamsSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        uint32 deadline = uint32(block.timestamp) + 3600;
        // Sign (maxFeeCctp 1e5, threshold 1000), submit (5e4, 2000).
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_VANILLA_CCTP_TYPEHASH, keccak256(route), 100e6, 1e6, 1e5, uint32(1000), deadline)
        );
        bytes memory sig = _sign(signerPk, _domainSeparator("CounterfactualDepositVanillaCCTP", proxy), structHash);
        bytes memory submitter = abi.encode(
            VanillaCCTPSubmitterData({
                amount: 100e6,
                executionFeeRecipient: relayer,
                executionFee: 1e6,
                maxFeeCctp: 5e4,
                minFinalityThreshold: 2000,
                signatureDeadline: deadline,
                counterfactualSignature: sig
            })
        );

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositVanillaCCTP.InvalidSignature.selector);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);
    }

    /// @dev The signature binds `routeParamsHash`; a signature for a different route must revert even when
    ///      the submitted route is itself a valid leaf.
    function testWrongRouteSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        uint32 deadline = uint32(block.timestamp) + 3600;
        // Sign a different route's hash.
        VanillaCCTPRouteParams memory other = _routeParams();
        other.destinationDomain = 6;
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_VANILLA_CCTP_TYPEHASH,
                keccak256(abi.encode(other)),
                100e6,
                1e6,
                1e5,
                uint32(1000),
                deadline
            )
        );
        bytes memory sig = _sign(signerPk, _domainSeparator("CounterfactualDepositVanillaCCTP", proxy), structHash);
        bytes memory submitter = abi.encode(
            VanillaCCTPSubmitterData({
                amount: 100e6,
                executionFeeRecipient: relayer,
                executionFee: 1e6,
                maxFeeCctp: 1e5,
                minFinalityThreshold: 1000,
                signatureDeadline: deadline,
                counterfactualSignature: sig
            })
        );

        vm.prank(user);
        token.transfer(proxy, 100e6);
        vm.prank(relayer);
        vm.expectRevert(CounterfactualDepositVanillaCCTP.InvalidSignature.selector);
        ICounterfactualDeposit(proxy).execute(address(vanillaImpl), route, submitter, proof);
    }
}
